# sq 버전 비교 — sq vs sq-v2 vs sq-v3

> 작성일: 2026-05-04  
> 위치: `tmux/sq/`

---

## 1. 한 줄 요약

| 버전 | 목적 |
|------|------|
| **sq** | OpenSearch 쿼리·API 코드를 직접 수정하는 개발 워크플로 |
| **sq-v2** | 검색 품질을 측정·진단하는 평가 워크플로 |
| **sq-v3** | 검색 데이터(search_keywords 관련 테이블)를 수정하는 개선 워크플로 |

---

## 2. 목적 비교

| 항목 | sq | sq-v2 | sq-v3 |
|------|-----|-------|-------|
| 핵심 목적 | 코드 수정 | 품질 측정·진단 | 데이터 수정·개선 |
| DB 접근 | read-only 조회 | read-only 조회 | read-only 조회 + SQL 파일 생성 |
| 코드 변경 | ✅ OpenSearch DSL, API 코드 변경 | ❌ 읽기만 | ❌ 읽기만 (SQL은 별도 검토 후 적용) |
| 주요 산출물 | 수정된 코드 + PR | scores.json + report.md | scores.json + fix_search_keywords.sql + fix_preview.md + report.md |

---

## 3. 에이전트 구성

### sq (v1)
```
Wave A (병렬): opensearch · api · runner
Wave B (순차): scorer
Wave C (순차): reporter
```

| 에이전트 | 역할 |
|---------|------|
| opensearch | OpenSearch 쿼리 DSL 수정, boost/weight 조정, 인덱스 매핑 변경 |
| api | 검색 API 엔드포인트 파라미터 수정, 응답 구조 변경 |
| runner | 키워드 500개 수집 (웹서칭250 + DB250) + 검색 API 배치 실행 |
| scorer | v1 채점 체계 — FALLBACK → F 강제, extracted_brands → relevance 1.0 자동 부여 |
| reporter | 기본 리포트 생성 |

### sq-v2
```
Wave A (병렬): opensearch* · api* · runner  (* = 선택사항)
Wave B (순차): scorer
Wave C (순차): reporter
```

| 에이전트 | v1 대비 변경 |
|---------|------------|
| runner | 동일 — 키워드 500개 (웹서칭250 + DB250, rank 상위 기준) |
| scorer | **v2 채점 체계**: POSSIBLE_FALLBACK(F 강제 폐기), diagnosis_codes 배열, ZERO 하위분류, PRE-FETCH 최적화 |
| reporter | **백엔드 알고리즘 컨텍스트 추가**: 파이프라인 흐름, diagnosis_codes→수정대상 테이블 매핑 포함 |

### sq-v3
```
Wave A (순차 전제): runner
Wave B (순차): scorer
Wave C (순차): keyword_fixer  ← 신규
Wave D (순차): reporter
```

| 에이전트 | v2 대비 변경 |
|---------|------------|
| runner | **v3 전략**: rank 상위 → ZERO_RESULT(150) + ETC_TYPE(100) + NO_SYNONYM(100) + POSSIBLE_FALLBACK(100) 유형별 수집 |
| scorer | **fixable 필드 추가**: fixable, fix_type, fix_priority |
| **keyword_fixer** | **신규**: scores.json → PHASE 2 컨텍스트 조회 → fix_search_keywords.sql + fix_preview.md 생성 |
| reporter | **§7 수정 계획 요약, §8 SQL 미리보기 추가** (reporter-v3 사용) |

---

## 4. 점수 체계 변화

### sq (v1) — 폐기된 방식
- FALLBACK 감지: total_count > 1000 → F 등급 강제
- extracted_brands 있으면 relevance_ratio = 1.0 자동 부여 (LLM 판단 없음)
- 단순 diagnosis (단일 문자열)

### sq-v2 / sq-v3 (공통 채점 체계)
| 항목 | 배점 | 설명 |
|------|------|------|
| 결과 존재성 | 10점 | result_count > 0 여부 |
| 검색 범위 적절성 | 15점 | 엔터티 발골 성공 여부 + total_count 범위 |
| 의도 파악 정확도 | 20점 | 발골 결과와 상품 일치 비율 (유형 A/B/C/D/E) |
| 결과 관련성 | 30점 | LLM 독립 평가 (Y/N 판단) |
| 상위 노출 품질 | 20점 | 관련 상품의 최상위 노출 순위 |
| 품절 상품 노출 | 5점 | soldout_rate |

#### segment 분류
| segment | 정의 | 평균 점수 포함 여부 |
|---------|------|-----------------|
| GENERAL | 정상 결과 | ✅ 포함 |
| POSSIBLE_FALLBACK | extracted 없음 + total_count > 2000 | ✅ 포함 (v1과 달리 F 강제 없음) |
| ZERO_RESULT | result_count = 0 | ❌ 제외 |

### sq-v3 추가 필드
```json
{
  "fixable": true,
  "fix_type": "INSERT_KEYWORD",
  "fix_priority": "HIGH"
}
```

---

## 5. 키워드 수집 전략 비교

| | sq / sq-v2 | sq-v3 |
|--|-----------|-------|
| 웹서칭 | 250개 (트렌드 키워드) | 50개 (보완용) |
| DB | 250개 — rank 상위 순 (스모크 테스트 중심) | 450개 — 유형별 우선순위 수집 |
| DB 전략 | rank 상위 → 서비스 대표 키워드 측정 | ZERO_RESULT(150)+ETC_TYPE(100)+NO_SYNONYM(100)+POSSIBLE_FALLBACK(100) → 수정 효과 최대화 |
| 총합 | 500개 | 500개 (중복 제거 후) |

---

## 6. DB 쿼리 파일 구조

| 파일 | 대상 | 설명 |
|------|------|------|
| (없음) | sq / sq-v2 | DB 조회는 에이전트 프롬프트에 인라인 포함 |
| `sq-v3-db-analysis.sql` | sq-v3 사전 분석 | 구현 전 수정 규모 파악용 1회성 쿼리 |
| `sq-v3-read-queries.sql` | sq-v3 실행 중 | PHASE 1(runner 입력) + PHASE 2(keyword_fixer 컨텍스트) + PHASE 3(before 스냅샷) |

---

## 7. 게이트 체크 비교

| 게이트 항목 | sq | sq-v2 | sq-v3 |
|-----------|-----|-------|-------|
| 검색 결과 JSON ≥ 100개 | ✅ | ✅ | ✅ |
| scores.json 존재 | ✅ | ✅ | ✅ |
| 리포트 파일 3개 존재 | ✅ | ✅ | ✅ |
| F등급 0건 비율 | ℹ️ 정보성 | ℹ️ 정보성 | ℹ️ 정보성 |
| **fix_search_keywords.sql 존재** | ❌ 없음 | ❌ 없음 | ✅ **v3 신규** |

---

## 8. 산출물 비교

| 산출물 | sq | sq-v2 | sq-v3 |
|--------|-----|-------|-------|
| `scores.json` | ✅ (v1 체계) | ✅ (v2 체계) | ✅ (v2+fixable) |
| `search-quality-report.md` | ✅ | ✅ | ✅ (§7,§8 추가) |
| `search-quality-detail.md` | ✅ | ✅ | ✅ (fix 컬럼 추가) |
| `search-quality-detail.csv` | ✅ | ✅ | ✅ (fix 컬럼 추가) |
| `fix_search_keywords.sql` | ❌ | ❌ | ✅ **v3 신규** |
| `fix_preview.md` | ❌ | ❌ | ✅ **v3 신규** |
| `snapshot_before_fix.csv` | ❌ | ❌ | ✅ **v3 신규** |
| `runner_*.csv` (유형별) | ❌ | ❌ | ✅ **v3 신규** |
| `impact_analysis.md` | ✅ (코드 변경 영향) | ✅ | ✅ (SQL 영향도) |

---

## 9. DB 접근 전략 비교

```
sq / sq-v2:
  read-only replica → 조회만

sq-v3 현재 (read-only 단계):
  read-only replica → 조회 + SQL 파일 생성 → 사람이 검토 후 직접 적용

sq-v3 추후 (write 권한 확보 후):
  read-only replica → 조회
  write 계정 → SQL 자동 실행 (sql_applier 에이전트, 사람 승인 후)
  before/after 비교 리포트 생성
```

---

## 10. 실행 명령

```bash
# sq (v1) — OpenSearch/API 코드 수정 목적
sq "OpenSearch 검색 쿼리 가중치 조정"

# sq-v2 — 검색 품질 측정·진단 목적
sq-v2 "40~50대 남성 패션 키워드 500개 품질 평가"
sq-v2   # 기본값: 40~50대 남성 패션 키워드 500개

# sq-v3 — search_keywords 데이터 수정·개선 목적
sq-v3 "search_keywords 개선 — 유사도/관련 상품 노출 향상"
sq-v3   # 기본값: search_keywords 개선

# reporter 독립 실행
FLAG_DIR=.agent/sq-v2-XXXX SQ_OUTPUT_DIR=docs/reports/sq-v2-XXXX reporter-v2
FLAG_DIR=.agent/sq-v3-XXXX SQ_OUTPUT_DIR=docs/reports/sq-v3-XXXX reporter-v3
```
