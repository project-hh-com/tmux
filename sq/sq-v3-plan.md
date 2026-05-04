# sq-v3 분석 및 구현 계획

> 작성일: 2026-05-04
> 목적: search_keywords 및 관련 테이블을 수정해 유사도·관련 상품 노출 개선
> 상태: 분석 완료 / 코드 구현 대기

---

## 1. sq-v2와의 차이

| 항목 | sq-v2 | sq-v3 |
|------|-------|-------|
| 목적 | 검색 품질 **측정·진단** | 검색 데이터 **수정·개선** |
| DB 접근 | read-only replica | read-only 조회 + SQL 파일 생성 (→ 추후 write 적용) |
| 주요 출력 | scores.json + report.md | scores.json + fix_search_keywords.sql + fix_preview.md |
| 에이전트 추가 | — | `keyword_fixer` 신규 추가 |
| Runner 전략 | rank 상위 + 트렌드 | ZERO_RESULT + ETC_TYPE + NO_SYNONYM 우선 |

---

## 2. 백엔드 검색 파이프라인 (수정 근거)

sq-v3가 수정하는 테이블은 아래 파이프라인의 어느 단계에 영향을 주는지 정확히 이해해야 합니다.

```
입력 query
  → QueryAnalyzer.normalize()
  → OpenSearch Analyze API (nori tokenizer, decompound_mode=none)
  → TokenClassifier.classify(tokens, domain=PRODUCT)
      ├─ _classify_tokens()
      │    └─ search_keywords 테이블 매칭         ← [수정 1] keyword 미등록 → INSERT
      ├─ _expand_keywords()
      │    └─ search_keyword_relations (SAME)     ← [수정 2] NO_SYNONYM → SAME INSERT
      └─ _classify_for_product()
          ├─ BRAND  발골 → search_brand_keywords  ← [수정 3] 매핑 누락/오류 → INSERT/UPDATE
          ├─ COLOR  발골 → search_color_keywords
          └─ CATEGORY 발골 → search_category_keywords ← [수정 4] 매핑 누락/오류 → INSERT/UPDATE
  → 발골 결과 전부 없음 → 즉시 빈 결과            ← ZERO_UNRECOGNIZED 발생 지점
  → _search_with_fallback()
      ├─ Tier 1: 원본 + SAME 동의어만 검색
      └─ Tier 2 (Tier 1 = 0건): + SIMILAR 포함   ← [수정 5] SIMILAR INSERT
```

### 파이프라인 특이사항
- `decompound_mode=none` → 복합어 미분해. "린넨셔츠"를 "린넨"+"셔츠"로 분해하지 않음
- 쿼리 토크나이징 코드 주석 처리 상태 → 형태소 단위 분리 미사용
- `is_sold_out` 기본 필터 없음 → 품절 상품 상위 노출 가능
- `min_score: 0.3` — should 쿼리 있을 때만 적용
- CATEGORY와 BRAND가 동시 발골되면 **CATEGORY 우선** (브랜드 필터 제거됨)

---

## 3. 수정 대상 테이블 × diagnosis_codes 매핑

| diagnosis_code | 파이프라인 실패 지점 | 수정 테이블 | fix_type |
|---------------|-----------------|-----------|---------|
| ZERO_UNRECOGNIZED | _classify_tokens 매칭 실패 → 발골 전부 없음 | `search_keywords` INSERT | INSERT_KEYWORD |
| ZERO_NO_MATCH | Tier 1 & 2 모두 0건 | `search_keyword_relations` SIMILAR INSERT | ADD_SIMILAR |
| ETC_TYPE | keyword_type=ETC → must 필터 없이 should만 | `search_keywords` keyword_type UPDATE + 매핑 INSERT | FIX_KEYWORD_TYPE |
| NO_SYNONYM | _expand_keywords SAME 0건 → Tier 1 원본만 | `search_keyword_relations` SAME INSERT | ADD_SYNONYM |
| POSSIBLE_FALLBACK | extracted_brands/category 없음 → should 전체 검색 | `search_category_keywords` or `search_brand_keywords` INSERT | FIX_CATEGORY_MAPPING / FIX_BRAND_MAPPING |
| BRAND_MAPPING_WRONG | brand.id 필터 엉뚱함 | `search_brand_keywords` brand_id UPDATE | FIX_BRAND_MAPPING |
| CATEGORY_MAPPING_WRONG | product_type/midtype 불일치 | `search_category_keywords` UPDATE | FIX_CATEGORY_MAPPING |
| LOW_RELEVANCE | OpenSearch 분석기 이슈 | 코드 수정 필요 (NOT_FIXABLE — sq-v3 범위 외) | NOT_FIXABLE |
| SOLDOUT_EXPOSED | is_sold_out 필터 없음 | 코드 수정 필요 (NOT_FIXABLE — sq-v3 범위 외) | NOT_FIXABLE |

---

## 4. DB 접근 전략 (2단계)

### 현재 단계 — Read-Only (지금 구현)
- 계정: `danble_read_only` (read replica)
- 역할: 진단용 조회 + SQL 파일 생성
- 출력: `fix_search_keywords.sql` — 사람이 검토 후 직접 적용
- 관련 파일: `sq-v3-read-queries.sql`

### 추후 단계 — Write 적용 (나중에 추가)
- 계정: write 계정 (`~/.config/sq/db_write.env` 별도 파일)
- 역할: keyword_fixer가 생성한 SQL을 자동 실행
- 방식: `sq-setup`에 write 계정 옵션 추가
- 조건: SQL 미리보기 검토 → 사람이 승인 후 실행 (안전 장치 유지)

---

## 5. sq-v3 웨이브 구조

```
Phase 1: Architect
  → plan.md 생성
  → agents.txt 선택 (runner / scorer / keyword_fixer / reporter)

Wave A (병렬): runner
  → sq-v3-read-queries.sql PHASE 1 실행
    - [R-1] ZERO_RESULT 키워드 수집 → runner_zero_result.csv
    - [R-2] ETC_TYPE 키워드 수집   → runner_etc_type.csv
    - [R-3] NO_SYNONYM 키워드 수집 → runner_no_synonym.csv
    - [R-4] POSSIBLE_FALLBACK 후보 → runner_possible_fallback.csv
  → 검색 API 호출 (curl) → results/*.json

Wave B (순차): scorer
  → results/*.json 읽고 채점
  → scores.json 생성 (fixable / fix_type 필드 포함)

Wave C (순차): keyword_fixer  ← 신규
  → scores.json 읽기
  → sq-v3-read-queries.sql PHASE 2 실행 (키워드별 컨텍스트 조회)
    - [F-1] 각 진단 키워드 전체 컨텍스트
    - [F-2] 브랜드 이름 → brand_id 조회
    - [F-3] product_type 목록 조회
    - [F-4] 유사 키워드 존재 여부 확인
    - [F-5] relation_score 범위 확인
    - [F-6] 같은 category_main 키워드 탐색
  → sq-v3-read-queries.sql PHASE 3 실행 (before 스냅샷)
    - [A-1] snapshot_before_fix.csv 저장
  → fix_search_keywords.sql 생성  ← ⚠️ 현재는 read-only이므로 미실행
  → fix_preview.md 생성

Wave D (순차): reporter
  → scores.json + fix_preview.md 읽기
  → search-quality-report.md 생성 (§7 수정 계획 섹션 포함)
  → search-quality-detail.md / .csv 생성
```

### 추후 Wave C 이후 추가 (write 권한 확보 시)
```
Wave C-2: sql_applier  ← 나중에 추가
  → fix_search_keywords.sql 검토 화면 표시
  → 사람 승인 후 write 계정으로 SQL 실행
  → snapshot_after_fix.csv 저장

Wave D-2: before/after reporter  ← 나중에 추가
  → snapshot_before_fix.csv vs snapshot_after_fix.csv 비교
  → 개선 효과 리포트 생성
```

---

## 6. Scorer 변경 사항 (fixable 필드 추가)

현재 scores.json 스키마에 아래 필드 추가 필요:

```json
{
  "keyword": "맨투맨",
  "segment": "ZERO_RESULT",
  "diagnosis_codes": ["ZERO_UNRECOGNIZED"],

  // ── sq-v3 신규 필드 ──────────────────────────────────
  "fixable": true,
  "fix_type": "INSERT_KEYWORD",
  "fix_priority": "HIGH"
  // fix_priority 기준:
  //   HIGH   = ZERO_RESULT + rank 상위 (즉각 개선 효과)
  //   MEDIUM = ETC_TYPE, NO_SYNONYM, POSSIBLE_FALLBACK
  //   LOW    = ZERO_RESULT + rank 없음, SIMILAR 추가
  //   NONE   = NOT_FIXABLE (LOW_RELEVANCE, SOLDOUT_EXPOSED)
}
```

---

## 7. keyword_fixer 에이전트 역할 프롬프트 (초안)

```
당신은 keyword_fixer 에이전트입니다.
sq-v3의 scorer가 생성한 ${FLAG_DIR}/scores.json 을 읽어
search_keywords 관련 테이블의 수정 SQL을 생성하세요.

## 참고 파일
- scores.json: ${FLAG_DIR}/scores.json
- 컨텍스트 쿼리: sq-v3-read-queries.sql (PHASE 2 쿼리 사용)
- before 스냅샷: ${FLAG_DIR}/snapshot_before_fix.csv

## 수정 원칙
1. read-only DB에서 필요한 ID(brand_id, keyword_id 등)를 먼저 조회합니다.
2. 조회 결과 기반으로 실행 가능한 SQL을 생성합니다.
3. 모든 SQL은 트랜잭션으로 감쌉니다 (BEGIN / COMMIT).
4. ⚠️ 현재는 SQL 파일만 생성합니다. 직접 실행하지 마세요.
   (write 권한 계정이 없습니다 — read-only 계정으로는 실행 불가)

## 출력

### fix_search_keywords.sql
트랜잭션 포함 실행 가능한 SQL:
  - INSERT INTO search_keywords ...
  - UPDATE search_keywords SET keyword_type = ... WHERE id = ...
  - INSERT INTO search_keyword_relations ...
  - INSERT INTO search_brand_keywords ...
  - INSERT INTO search_category_keywords ...

### fix_preview.md
| fix_type | keyword | 변경 내용 | 근거 | 예상 효과 |
형식으로 수정 내용 요약

## 백엔드 검색 파이프라인 (수정 근거)
[이전 섹션의 파이프라인 컨텍스트 전체 삽입]
```

---

## 8. Reporter 변경 사항 (§7, §8 섹션 추가)

현재 reporter-v2 프롬프트에 아래 섹션 추가:

```markdown
## 7. 수정 계획 요약 (keyword_fixer 결과)
| fix_type | 키워드 수 | 우선순위 | 예상 효과 |
|---------|---------|---------|---------|
| INSERT_KEYWORD | N | HIGH | ZERO_UNRECOGNIZED → 검색 가능 |
| ADD_SYNONYM | N | MEDIUM | 동의어 확장으로 결과 다양성 증가 |
| FIX_KEYWORD_TYPE | N | MEDIUM | ETC→BRAND/CATEGORY → 정확 필터 |
| ADD_SIMILAR | N | LOW | Tier 2 폴백 활성화 |
| FIX_CATEGORY_MAPPING | N | MEDIUM | POSSIBLE_FALLBACK 해소 |
| FIX_BRAND_MAPPING | N | MEDIUM | 브랜드 정확도 개선 |
| NOT_FIXABLE | N | — | 코드 수정 필요 (sq-v3 범위 외) |

## 8. 생성된 SQL 미리보기
⚠️ 아래 SQL은 read-only 계정으로는 실행 불가합니다.
   write 권한 확보 후 검토 후 적용하세요.
SQL 파일: {FLAG_DIR}/fix_search_keywords.sql
(처음 30줄 미리보기)
```

---

## 9. 관련 파일 목록

| 파일 | 역할 | 상태 |
|------|------|------|
| `sq-v3-read-queries.sql` | sq-v3 실행 중 사용하는 read-only 쿼리 모음 | ✅ 작성 완료 |
| `sq-v3-db-analysis.sql` | sq-v3 구현 전 규모 파악용 1회성 분석 쿼리 | ✅ 작성 완료 |
| `sq-v3-plan.md` | 이 문서 | ✅ 작성 완료 |
| `sq-v3` | sq-v3 메인 스크립트 | ⏳ 구현 대기 |
| `reporter-v2` | sq-v2 reporter (백엔드 알고리즘 컨텍스트 추가됨) | ✅ 수정 완료 |

---

## 10. 구현 체크리스트

### 지금 할 수 있는 것 (read-only)
- [x] sq-v3-read-queries.sql 작성
- [x] sq-v3-db-analysis.sql 작성 (사전 규모 파악)
- [x] reporter-v2 백엔드 컨텍스트 추가
- [ ] sq-v3 메인 스크립트 작성 (sq-v2 fork)
- [ ] keyword_fixer 에이전트 스크립트 작성
- [ ] scorer v3 (fixable 필드 추가)
- [ ] reporter v3 (§7, §8 섹션 추가)

### write 권한 확보 후
- [ ] sq-setup에 db_write.env 옵션 추가
- [ ] sql_applier 에이전트 작성 (승인 후 실행)
- [ ] before/after 비교 reporter 작성
