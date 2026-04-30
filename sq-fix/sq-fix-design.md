# sq-fix 명령어 설계 분석

> sq에서 생성된 최신 리포트를 기반으로 검색 알고리즘 정확도를 자동 개선하는 에이전트 시스템
>
> 작성일: 2026-04-30  
> 기반 분석: sq 원본 코드(1861줄) + sq-20260430-141805 리포트 + danble-backend 검색 코드 실제 분석

---

## 1. 개요 및 목적

### sq vs sq-fix 포지셔닝

```
sq                         →  sq-fix
검색 품질 "측정"             →  검색 품질 "수정"
키워드 500개 배치 실행        →  리포트의 문제 패턴 분석 후 코드/DB 수정
결과 → 리포트 → PR           →  수정 → 재검증 → PR
```

sq는 **무엇이 문제인지** 를 찾아낸다.  
sq-fix는 **그 문제를 실제로 고친다.**

### 핵심 원칙

- sq가 생성한 리포트를 유일한 인풋으로 사용
- 코드/DB 수정 후 해당 키워드만 재검증 (500개 전체 재실행 X)
- sq와 동일한 Phase 구조, 다른 에이전트 역할
- 모든 수정은 설명 가능하고 되돌릴 수 있어야 함

---

## 2. 실제 검색 코드 구조 (danble-backend 분석)

> sq-fix 에이전트가 수정해야 할 파일과 로직을 정확히 알기 위해 실제 코드를 분석했다.

### 검색 모듈 위치

```
danble-api/search/
├── models/
│   ├── search_keyword.py              # 키워드 사전 (keyword_type 포함)
│   ├── search_keyword_relation.py     # 동의어(SAME) / 유사어(SIMILAR)
│   ├── search_brand_keyword.py        # 브랜드 발골 사전
│   ├── search_category_keyword.py     # 카테고리 발골 사전
│   └── search_color_keyword.py        # 색상 발골 사전
├── services/
│   └── search_products_service.py     # ✅ 핵심: v3 검색 + Tier 1/2 fallback
├── domains/
│   ├── token_classifier.py            # ✅ 핵심: 엔터티 발골 (BRAND/COLOR/CATEGORY)
│   └── query_analyzer.py              # 쿼리 정규화 + 토크나이징
└── repositories/
    └── search_keyword_repo.py         # 키워드 캐시 (Redis, TTL 10분)

danble-search/
└── chalicelib/statics/
    └── product_index_config.json      # ✅ OpenSearch 인덱스 매핑 + 분석기 설정
```

### 검색 요청의 실제 실행 흐름

```
GET /api/v1/search/product-results?query=나이키
  ↓
1. query_analyzer.normalize() → 특수문자 제거, 소문자, strip
2. query_analyzer.tokenize()  → OpenSearch nori_tokenizer 호출
   - "나이키 에어포스" → ["나이키", "에어포스"]
3. token_classifier.classify() → 엔터티 발골
   - search_keywords 테이블 매칭 → KeywordInfoDTO 생성
   - search_brand_keywords 조인  → extracted_brands = [brand_id: 123]
   - search_category_keywords 조인 → extracted_category
   - search_keyword_relations 조인 → SAME(동의어) / SIMILAR(유사어)
4. _search_with_fallback()
   - Tier 1: extracted 엔터티로 must 필터 + remaining 토큰으로 should 쿼리
   - total_count == 0이면 → Tier 2: SIMILAR 유사어까지 포함
5. OpenSearch 실행 → product_ids 반환
6. ProductQueryFacade → 실제 상품 데이터 조회
7. VisibilityContext → is_sold_out 등 후처리 필터 적용
```

### keyword_type이 검색에 미치는 실제 영향

이것이 **P1 문제(ETC 타입)의 핵심 원인**이다:

```python
# token_classifier.py 내 엔터티 발골 로직
def _extract_brands_from_keywords(keywords):
    # search_brand_keywords 테이블에 있는 것만 브랜드로 발골
    # keyword_type과 무관 — 발골사전 테이블 등록 여부로 결정

def _extract_category_from_keywords(keywords):
    # search_category_keywords 테이블에 있는 것만 카테고리로 발골
    # keyword_type과 무관 — 발골사전 테이블 등록 여부로 결정
```

**결론**: `keyword_type = ETC`가 검색 자체를 방해하지는 않는다.  
진짜 문제는 **sq scorer의 관련성 판단 로직**이 `keyword_type`에 의존하기 때문이다.  
즉 P1은 "검색 품질 문제"가 아니라 **"채점 기준 문제"** 일 수 있다.

→ `keyword_type` 업데이트 OR sq scorer 프롬프트 개선 두 가지 접근 모두 유효.

### FALLBACK의 실제 발생 메커니즘

```python
# search_products_service.py
def _search_with_fallback(analyzed, ...):
    # Tier 1: extracted_brands/colors/category로 must 필터 → 결과 없으면
    # Tier 2: SIMILAR 유사어 포함 → 그래도 결과 없으면 빈 결과 반환
```

**sq 리포트의 "FALLBACK" (total_count > 1000)은 실제로 다른 문제다:**  
- sq가 감지하는 FALLBACK = "결과가 너무 많음" (entity 발골 실패 → 전체 제품 반환)
- 실제 코드의 Tier 2 fallback = "결과 없을 때 유사어로 확장"
- 즉 "가죽", "팬츠" 같은 키워드는 search_category_keywords에 등록되어 있지 않아서 category 발골이 안 되고, 단순 should 쿼리로만 실행 → 광범위한 결과 반환

→ 이 케이스는 `search_category_keywords` 테이블에 카테고리 매핑 추가로 해결 가능.

### Tier 1/2 Fallback 코드 (실제)

```python
# Tier 1: 동의어(SAME)까지만
tier1_result = _execute_search(use_expanded=False)
if tier1_result["total_count"] > 0:
    return SearchProductsResult(..., fallback_tier=1)

# Tier 2: 유사어(SIMILAR)까지 포함
tier2_result = _execute_search(use_expanded=True)
return SearchProductsResult(..., fallback_tier=2)
```

`search_keyword_relations.relation_type`:
- `"SAME"` = 동의어 → Tier 1 포함
- `"SIMILAR"` = 유사어 → Tier 2에만 포함

### decompound_mode 실제 값 확인

`product_index_config.json` 실제 코드:
```json
{
  "tokenizer": {
    "nori_tokenizer": {
      "type": "nori_tokenizer",
      "decompound_mode": "none"
    }
  }
}
```

`decompound_mode: "none"` = 복합어를 분리하지 않음
- "데님팬츠" → ["데님팬츠"] (분리 안 됨)
- "데님" 검색 시 "데님팬츠" 상품을 name 필드에서 못 찾을 수 있음
- 대응: `search_keyword_relations`에 "데님" → "데님팬츠" SIMILAR 관계 추가

### is_sold_out 처리 방식 (실제)

- OpenSearch 인덱스에는 `is_sold_out` 필드 존재 ✅
- OpenSearch 쿼리에서는 **필터하지 않음** ❌
- 대신 `ProductQueryFacade.get_product_displays()`에서 후처리 필터링
- 즉 sq scorer의 "품절 노출 점수"는 OpenSearch 결과를 기준으로 채점하므로, 품절 상품이 검색 결과에 포함된 것처럼 보임

→ `is_sold_out` 필터를 OpenSearch 쿼리 레벨로 올리는 것이 실질적 개선이나, 비즈니스 결정 필요.

### 코드에서 발견된 디버그 로그 (제거 필요)

```python
# search_products_service.py line 256
print(f"IDS: {product_ids}")  # ← 프로덕션 코드에 print 잔존

# token_classifier.py lines 103-109
print(f"extracted_brands: ...")  # ← 여러 개의 print 잔존
```

→ code-fixer 에이전트 작업 목록에 포함.

### sq-fix가 수정할 실제 파일 목록

| 파일 | 수정 유형 | 목적 |
|-----|---------|-----|
| `search_keywords` (DB) | INSERT / UPDATE | keyword_type 교정, 미등록 키워드 추가 |
| `search_brand_keywords` (DB) | INSERT | 브랜드 발골 사전 추가 |
| `search_category_keywords` (DB) | INSERT | 카테고리 발골 사전 추가 (FALLBACK 해소) |
| `search_keyword_relations` (DB) | INSERT | 동의어/유사어 추가 |
| `product_index_config.json` | 코드 수정 | synonym filter 추가 (스페이싱 variant) |
| `search_products_service.py` | 코드 수정 | print 제거, is_sold_out 필터 옵션 |
| `token_classifier.py` | 코드 수정 | print 제거 |

---

## 3. 리포트 분석: 어떤 문제를 고쳐야 하는가

최신 리포트(sq-20260430-141805) 분석 결과, 수정 가능한 문제는 6개 카테고리로 분류된다.

### 문제 카테고리 및 규모

| # | 문제 유형 | 영향 키워드 수 | 개선 난이도 | 예상 점수 상승 |
|---|---------|------------|----------|------------|
| P1 | ETC 키워드 타입 재분류 | ~145개 | 중 | +15~20점 |
| P2 | 미등록 키워드 사전 추가 | ~77개 | 낮음 | +20점 (ZERO→GENERAL) |
| P3 | FALLBACK 엔터티 매핑 | 36개 | 중 | +20점 (FALLBACK→GENERAL) |
| P4 | 카테고리 매핑 누락 | 29개 | 낮음 | +10점 |
| P5 | 동의어/유사어 등록 누락 | 9개 | 낮음 | +5점 (안전망) |
| P6 | OpenSearch 쿼리 로직 | 코드 수정 | 높음 | +10~20점 |

### 핵심 수치 (현재 상태)

```
전체 500 키워드 기준:
  GENERAL   : 400개 (80.0%)  ← 정상 결과
  FALLBACK  :  36개 ( 7.2%)  ← 전체 제품 반환 (entity 추출 실패)
  ZERO_RESULT:  64개 (12.8%)  ← 결과 없음

GENERAL 400개 내 점수 분포:
  A (85+)  : 189개 (47.2%)
  B (70-84):  65개 (16.2%)
  C (50-69):  58개 (14.5%)
  D (30-49):  88개 (22.0%)  ← 대부분 ETC 타입 문제

현재 종합 평균: 59.6점 / 100
수정 후 예상 평균: 72+ 점
```

### 수정 대상 상세

#### P1. ETC 키워드 타입 재분류 (145개)

`keyword_type = ETC`인 키워드는 sq scorer가 관련성을 판단할 수 없어 관련성 점수(30점) 0점으로 처리된다.

**⚠️ 코드 분석으로 밝혀진 중요 사실**: `keyword_type`은 실제 검색 쿼리 실행에 직접 영향을 주지 않는다. 엔터티 발골(`token_classifier.py`)은 `search_brand_keywords`, `search_category_keywords` 테이블 등록 여부로 결정된다. 즉 이 문제는 검색 품질 문제라기보다 **채점 기준 문제**다.

→ **두 가지 수정 방향 모두 유효**:
- 방향 A: `search_keywords.keyword_type` 업데이트 (단기, DB만 수정)
- 방향 B: `search_brand_keywords` 또는 `search_category_keywords` 테이블에 등록 (실제 검색 품질 향상)
- 방향 B가 근본 해결이며, keyword_type도 함께 교정하는 것이 이상적

**증상**: 실제 검색 결과는 존재하는데 D등급
```
아미 (AMI 브랜드) → 394개 결과 → 관련성 0점 → D등급
내셔널지오그래피  → 7개 결과  → 관련성 0점 → D등급
내셔널지오그래픽  → 결과 있음  → 관련성 100% → A등급  (search_brand_keywords에 등록됨)
```

**수정 방법**: 
1. `search_keywords.keyword_type` 업데이트 (BRAND/CATEGORY 등으로)
2. 해당 키워드를 `search_brand_keywords` 또는 `search_category_keywords`에 추가 등록

**대표 케이스**: 비르반테, 파렌하이트, 아미, 앤드지, 아페쎄, 톰브라운, 몽클레어(한글), 스톤아일랜드(한글), 발렌시아가, 프라다, 캉골, 지방시, 생로랑, 보테가베네타, 캐나다구스, 데상트, 바버, 카디건, 폴로셔츠, 다운자켓, 린넨셔츠, 아노락, 경량패딩 등

#### P2. 미등록 키워드 (77개 ZERO_RESULT)

`search_keywords` 테이블에 존재하지 않아 검색 자체가 안 되는 경우.

**수정 방법**: `search_keywords` 테이블에 신규 행 INSERT (+ `search_keyword_relations`에 유사어 연결)

**대표 케이스**: 양털자켓, 봄자켓, 겨울 코트, 스키니진, 와이드팬츠, 하이웨스트, 세미와이드, 더블브레스트, 싱글자켓, 에스파드류, 캠핑룩, 소개팅룩, 나들이룩, 산책룩, 카페룩, 피크닉룩, 휴양지룩, 출근룩, 일상룩, 운동룩

**주의**: 키워드 등록 시 중복 INSERT 방지 필요. 스페이싱 variants도 함께 등록.

#### P3. FALLBACK 엔터티 매핑 (36개)

`total_count > 1000`이거나 entity 추출이 실패해 전체 제품을 반환하는 경우.

**⚠️ 코드 분석으로 밝혀진 실제 원인**: "가죽", "팬츠", "오버핏" 같은 키워드는 `search_category_keywords` 테이블에 등록되지 않아 카테고리 발골이 실패한다. 결과적으로 should 쿼리(name 필드 전문 검색)만 실행되어 광범위한 결과가 반환된다. 실제 코드의 "Tier 2 fallback"(유사어 확장)과는 다른 개념이다.

**증상**: 일반 명사 키워드 → 카테고리 발골 실패 → must 필터 없음 → 전체 상품 중 name 매칭 → 10,000개 결과

**수정 방법 (코드 기반으로 확정)**:
- **핵심**: `search_category_keywords` 테이블에 카테고리 매핑 추가
  - "팬츠" → product_type="BOTTOM", product_midtype_ids=[...]
  - "오버핏" → is_service_midtype=False, requires_name_search=True, search_scope 설정
  - "가죽" → 소재 속성이라 직접 매핑 어려움 → `search_keyword_relations`에 구체적인 아이템 키워드 연결
- **주의**: `search_category_keywords.is_service_midtype` 값에 따라 쿼리 방식이 다름 (코드 섹션 2 참고)

**대표 케이스**: 가죽, 기모, 코듀로이, 린넨, 오버핏, 팬츠, 신발, 남성 캐주얼, 점퍼, 집업, 셋업, 윈드브레이커, 테크웨어, 워크웨어, 트레이닝바지

#### P4. 카테고리 매핑 누락 (29개)

브랜드나 occasion 키워드가 `search_category_keywords` 테이블에 없어 이중의도 점수(20점) 미적용.

**수정 방법**: `search_category_keywords` 테이블에 매핑 추가

**대표 케이스**: COS, H&M, 유니클로, 자라, 빈폴, 헤지스, 수트, 베스트, 오피스룩, 업무미팅룩, 소개팅룩, 데이트룩, 나들이룩, 산책룩, 카페룩, 출근룩, 일상룩, 운동룩, 원마일웨어

#### P5. 동의어/유사어 누락 (9개)

현재 A등급이지만 `search_keyword_relations`에 동의어/유사어가 0개 → Tier 2 fallback 보호망 없음.

**수정 방법**: `search_keyword_relations`에 관련 키워드 연결

**대표 케이스**: 몽벨, 디엠즈, 티엔지티, 브롬톤 런던, 에스티코, 내셔널지오그래픽, 나이키, 플리스

#### P6. 코드 레벨 수정 사항

코드 분석으로 확정된 실제 수정 대상.

**이슈 1: 스페이싱 변형 처리 실패**
```
"내셔널지오그래피"  (붙여쓰기) → search_brand_keywords에 없음 → 발골 실패 → D등급
"내셔널지오그래픽"  (영어식)  → search_brand_keywords에 등록됨 → A등급
```
- 원인: `decompound_mode: "none"` + 붙여쓰기 variant가 발골 사전에 미등록
- 수정: `search_keyword_relations`에 "내셔널지오그래피" → "내셔널지오그래픽" SAME 관계 추가
  또는 `product_index_config.json` synonym filter에 쌍 추가

**이슈 2: 한글 브랜드 vs 영문 브랜드 불일치**
```
"스톤아일랜드" → search_brand_keywords 미등록 → should만 실행 → 55점
"stone island" → search_brand_keywords 등록됨 → brand must 필터 → 100점
```
- 원인: 한글 브랜드명이 `search_brand_keywords`에 없음
- 수정: `search_brand_keywords`에 한글 브랜드명 추가 (P1 처리 시 함께 해결)

**이슈 3: decompound_mode 문제 — 코드에서 "none"으로 확인됨**
- 복합어 분리 없음 → "데님팬츠" 검색 시 "데님", "팬츠" 분리 안 됨
- `search_keyword_relations`에 복합어 ↔ 단어 SIMILAR 관계 추가로 완화 가능
- 인덱스 재설정 없이 DB 수정만으로 해결 권장

**이슈 4: 프로덕션 코드 내 print 디버그 로그 잔존**
- `search_products_service.py` line 256: `print(f"IDS: {product_ids}")`
- `token_classifier.py` lines 103-109: 다수 print 문
- 수정: `logger.debug()`로 교체 또는 제거 (글로벌 CLAUDE.md 규칙: 프로덕션 코드의 console.log 금지)

**이슈 5: is_sold_out 필터 위치 (선택적 개선)**
- 현재: OpenSearch 쿼리에서 필터 없음 → `ProductQueryFacade` 후처리 필터
- 개선 시: `must_not: [{"term": {"is_sold_out": true}}]` 추가 가능
- 단, 비즈니스 결정 필요 (품절 상품 노출 정책에 따라 다름) → Analyst가 판단

---

## 3. sq-fix 아키텍처 설계

### 실행 플로우 개요

```
sq-fix [리포트경로?]
  ↓
Phase 0: 초기화 (sq와 동일)
  ↓
Phase 1: Analyst — 리포트 분석 → 수정 계획 수립
  ↓
Debate 1: 수정 계획 검토 (Red/Blue/Judge)
  ↓
Phase 3: 3-Wave 수정 실행
  Wave A (병렬): db-fixer + code-fixer
  Wave B (순차): verifier (수정된 키워드만 재검증)
  Wave C (순차): reporter (before/after 비교 리포트)
  ↓
Debate 2: 수정 결과 검토
  ↓
Phase 3.5: 영향도 분석 (sq와 동일)
  ↓
Phase 4: 검증 게이트
  ↓
Phase 5: 자동 수정 (실패 시)
  ↓
Phase 6: Release Manager
```

### sq 대비 변경점 요약

| 항목 | sq | sq-fix |
|-----|-----|--------|
| 인풋 | 자유 텍스트 feature 요청 | 최신 리포트 경로 (자동 탐색) |
| Phase 1 에이전트 | Architect | Analyst |
| Wave A 에이전트 | opensearch + api + runner | db-fixer + code-fixer |
| Wave B 에이전트 | scorer | verifier |
| Wave C 에이전트 | reporter | reporter (before/after 비교) |
| Phase 4 게이트 | JSON ≥100 + scores.json + 3 파일 | 수정 건수 > 0 + 재검증 점수 > 기준 |
| 핵심 출력 | 점수 리포트 | 수정 내역 + 점수 개선 리포트 |

---

## 4. 에이전트 역할 상세 설계

### Phase 1: Analyst 에이전트

**역할**: 최신 리포트를 읽고 수정 우선순위를 결정, Wave A/B/C 에이전트 지시서 작성

**인풋**:
- `docs/reports/sq-{LATEST}/search-quality-report.md`
- `docs/reports/sq-{LATEST}/search-quality-detail.csv`
- `docs/reports/sq-{LATEST}/search-quality-detail.md`

**아웃풋**:
- `${FLAG_DIR}/analysis.md` — 문제 분류 및 수정 우선순위
- `${FLAG_DIR}/fix_targets.json` — 키워드별 수정 액션 목록
  ```json
  [
    {"keyword": "아미", "issue": "ETC_TYPE", "action": "UPDATE_TYPE", "new_type": "BRAND"},
    {"keyword": "양털자켓", "issue": "ZERO_RESULT", "action": "INSERT_KEYWORD"},
    {"keyword": "가죽", "issue": "FALLBACK", "action": "ADD_ENTITY_MAPPING"},
    ...
  ]
  ```
- `${FLAG_DIR}/code_issues.md` — OpenSearch 코드 수정이 필요한 패턴 목록
- `${FLAG_DIR}/agents.txt` — 필요 에이전트 목록 (db-fixer / code-fixer 선택)
- `${FLAG_DIR}/commit_msg.txt` — 커밋 메시지 요약

**에이전트 선택 기준**:
- DB 수정만 필요 (P1~P5): `db-fixer`, `verifier`, `reporter`
- 코드 수정 필요 (P6 포함): `db-fixer` + `code-fixer`, `verifier`, `reporter`

---

### Wave A-1: db-fixer 에이전트

**역할**: `fix_targets.json`을 기반으로 DB 수정 SQL 생성 및 실행

**주요 작업**:

1. **keyword_type 업데이트**
   ```sql
   UPDATE search_keywords 
   SET keyword_type = 'BRAND' 
   WHERE keyword = '아미' AND keyword_type = 'ETC';
   ```

2. **미등록 키워드 INSERT**
   ```sql
   INSERT INTO search_keywords (keyword, keyword_type, ...)
   VALUES ('양털자켓', 'ITEM', ...)
   ON CONFLICT (keyword) DO NOTHING;
   ```

3. **카테고리 매핑 추가**
   ```sql
   INSERT INTO search_category_keywords (keyword_id, category_id)
   VALUES (...);
   ```

4. **동의어/유사어 추가**
   ```sql
   INSERT INTO search_keyword_relations (keyword_id, related_keyword_id, relation_type)
   VALUES (...);
   ```

**안전 장치**:
- 모든 수정은 트랜잭션으로 묶어 실행
- 실행 전 `${FLAG_DIR}/db_fix_plan.sql` 파일 생성 (DRY RUN 먼저 출력)
- 실제 실행 후 `${FLAG_DIR}/db_fix_result.json`에 변경 건수 기록
- 읽기 전용 DB에는 실행 불가 → 별도 write connection 필요 (sq-setup 확장 필요)

**아웃풋**:
- `${FLAG_DIR}/db_fix_plan.sql` — 실행 예정 SQL
- `${FLAG_DIR}/db_fix_result.json` — 실행 결과
- `${FLAG_DIR}/db-fixer.done` — 완료 마커

**⚠️ 중요 고려사항**: 현재 sq는 `danble_read_only` 계정을 사용한다. db-fixer는 쓰기 권한이 있는 별도 계정이 필요하다. `sq-setup`에서 write 계정 설정 추가 필요.

---

### Wave A-2: code-fixer 에이전트

**역할**: `code_issues.md`를 기반으로 OpenSearch 쿼리 코드 수정

**주요 수정 대상 파일 (코드 분석으로 확정)**:
- `danble-search/chalicelib/statics/product_index_config.json` — synonym filter 추가
- `danble-api/search/services/search_products_service.py` — print 제거, is_sold_out 옵션
- `danble-api/search/domains/token_classifier.py` — print 제거

**주요 작업**:

1. **프로덕션 print 제거**: `search_products_service.py`, `token_classifier.py` 내 print 문 → `logger.debug()`로 교체
2. **synonym filter 추가**: `product_index_config.json`에 붙여쓰기/띄어쓰기 variant 쌍 추가
3. **is_sold_out 필터 (선택)**: Analyst가 점수 패턴 확인 후 추가 여부 결정

**안전 장치**:
- 수정 전 `git stash` 또는 별도 파일에 원본 보존
- 변경 파일 목록: `${FLAG_DIR}/code_fix_summary.md`

**아웃풋**:
- 실제 소스코드 수정
- `${FLAG_DIR}/code_fix_summary.md` — 변경 내역 요약
- `${FLAG_DIR}/code-fixer.done`

---

### Wave B: verifier 에이전트

**역할**: 수정된 키워드만 골라 실제 검색 API를 다시 호출하고 점수 개선을 확인

**인풋**:
- `${FLAG_DIR}/db_fix_result.json` — 수정된 키워드 목록
- `${FLAG_DIR}/code_fix_summary.md` — 코드 수정 영향 키워드 (있을 경우)
- 기존 `docs/reports/sq-{LATEST}/search-quality-detail.csv` — before 점수

**주요 작업**:

1. 수정된 키워드 리스트 추출 (최대 200개, 전체 재실행 아님)
2. 검색 API 호출 (sq의 runner와 동일한 방식)
3. sq의 scorer와 동일한 100점 기준으로 재채점
4. before/after 점수 비교

**채점 기준**: sq scorer와 완전히 동일 (100점 척도, 5개 항목)

**아웃풋**:
- `/tmp/sq-fix/keyword-{name}.json` — 재검증 결과 JSON
- `${FLAG_DIR}/verify_scores.json` — 재채점 결과
- `${FLAG_DIR}/verifier.done`

**⚠️ 주의**: verifier는 코드 수정 후 API를 호출하므로, code-fixer 작업이 실제 서비스에 반영되는 시점에 따라 검증 결과가 다를 수 있다. 스테이징 환경 vs 프로덕션 고려 필요.

---

### Wave C: reporter (before/after 비교)

**역할**: 수정 전/후 점수를 비교하는 리포트 생성

**인풋**:
- `docs/reports/sq-{LATEST}/search-quality-detail.csv` — before
- `${FLAG_DIR}/verify_scores.json` — after
- `${FLAG_DIR}/db_fix_result.json`
- `${FLAG_DIR}/code_fix_summary.md`

**아웃풋** (`docs/reports/sq-fix-{TIMESTAMP}/`):
- `fix-summary-report.md` — 수정 요약: 개선 건수, 점수 상승, 카테고리별 효과
- `fix-detail.md` — 키워드별 before/after 상세 테이블
- `fix-detail.csv` — CSV 전체 (before/after 컬럼 포함)

**리포트 포함 내용**:
```
수정 건수 요약:
  - keyword_type 업데이트: X개
  - 신규 키워드 등록: X개
  - 카테고리 매핑 추가: X개
  - 동의어 추가: X개
  - 코드 수정: X파일

점수 개선:
  - FALLBACK → GENERAL 전환: X개
  - ZERO_RESULT → GENERAL 전환: X개
  - 평균 점수 변화: XX → XX (+XX)
  - 등급 상승: XX개 (D→A: X, D→B: X, D→C: X, ...)
```

---

## 5. Phase 4 검증 게이트 (sq-fix 버전)

### 게이트 조건 (sq와 다름)

| # | 체크 항목 | 통과 기준 |
|---|---------|---------|
| 1 | db_fix_result.json 존재 | 파일 있음 + 수정 건수 > 0 |
| 2 | verify_scores.json 존재 | 파일 있음 + 채점 완료 |
| 3 | before/after 비교 가능 | 재검증 키워드 ≥ 10개 |
| 4 | 점수 개선 확인 | 재검증 키워드 평균 점수 before 대비 ≥ +5점 |
| 5 | 3개 리포트 파일 | fix-summary + fix-detail.md + .csv 존재 |

### 실패 시

- Phase 5 auto-fix: verifier 또는 reporter 재실행 (최대 2라운드)
- 점수 개선 미달 시: Debate 2에서 REWORK 고려

---

## 6. 리포트 탐색 로직

sq-fix 실행 시 인자가 없으면 최신 리포트를 자동으로 찾는다.

```bash
# 최신 리포트 탐색 순서
REPORTS_DIR="$(pwd)/docs/reports"
LATEST_REPORT=$(ls -d "${REPORTS_DIR}"/sq-* 2>/dev/null | sort | tail -1)

# sq-fix 리포트는 제외 (sq- 로 시작하는 것만)
LATEST_REPORT=$(ls -d "${REPORTS_DIR}"/sq-[0-9]* 2>/dev/null | sort | tail -1)

if [[ -z "$LATEST_REPORT" ]]; then
  echo "❌ sq 리포트를 찾을 수 없습니다. sq를 먼저 실행하세요."
  exit 1
fi
```

**명시적 지정도 지원**:
```bash
sq-fix                                          # 최신 리포트 자동 탐색
sq-fix docs/reports/sq-20260430-141805          # 특정 리포트 지정
sq-fix --report docs/reports/sq-20260430-141805 # 롱 옵션
```

---

## 7. DB 쓰기 권한 이슈 (핵심 선결 과제)

현재 sq는 `danble_read_only` 계정만 사용한다. db-fixer가 실제로 DB를 수정하려면:

### 옵션 A: sq-setup 확장 (권장)

`sq-setup`에 write 계정 설정 추가:
```bash
# ~/.config/sq/db.env 에 추가
PGUSER_WRITE="danble_write_user"
PGPASSWORD_WRITE="..."
```

db-fixer는 write 계정으로 접속, verifier는 read 계정으로 재검증.

### 옵션 B: 마이그레이션 파일 생성

실제 DB 수정 대신 Django migration 파일 또는 data fixture를 생성하고, 개발자가 직접 적용하는 방식.

- 장점: 안전, 리뷰 가능, 버전 관리
- 단점: 자동화 완전하지 않음

### 옵션 C: Admin API 사용

danble-brand-admin 또는 internal-admin의 API를 통해 키워드 등록.

- 장점: 기존 비즈니스 로직 경유
- 단점: 모든 수정 케이스가 API로 지원되지 않을 수 있음

**권장**: MVP는 옵션 B (마이그레이션 파일 생성), 이후 옵션 A로 업그레이드.

---

## 8. 파일 구조 설계

```
.agent/sq-fix-{TIMESTAMP}/
├── TIMELINE.md                    # sq와 동일
├── analysis.md                    # Analyst 분석 결과
├── fix_targets.json               # 키워드별 수정 액션 목록
├── code_issues.md                 # 코드 수정 항목
├── agents.txt                     # 선택된 에이전트
├── commit_msg.txt                 # 커밋 메시지
├── prompt_{N}.txt                 # 에이전트별 프롬프트
├── run_{N}_{agent}.sh             # 에이전트 실행 스크립트
├── db-fixer.done / code-fixer.done / verifier.done
├── db_fix_plan.sql                # 실행 예정 SQL (DRY RUN)
├── db_fix_result.json             # DB 수정 결과
├── code_fix_summary.md            # 코드 수정 요약
├── verify_scores.json             # 재채점 결과
├── debate_design_verdict.txt      # Debate 1 결과
├── debate_review_verdict.txt      # Debate 2 결과
├── impact_analysis.md             # 영향도 분석
├── release_report.md              # PR 생성 결과
├── SUMMARY.md                     # 전체 요약
├── analyst.log / db-fixer.log / code-fixer.log
└── verifier.log / reporter.log

docs/reports/sq-fix-{TIMESTAMP}/
├── fix-summary-report.md          # 수정 요약 리포트
├── fix-detail.md                  # 키워드별 before/after
└── fix-detail.csv                 # CSV 전체
```

---

## 9. 사용 예시

```bash
# 1. 최신 sq 리포트 기반 자동 수정
sq-fix

# 2. 특정 리포트 지정
sq-fix docs/reports/sq-20260430-141805

# 3. 수정 범위 제한 (선택적 지원)
sq-fix --only db          # DB 수정만 (코드 수정 skip)
sq-fix --only code        # 코드 수정만
sq-fix --priority P1,P2  # 우선순위 P1, P2만
```

---

## 10. 구현 시 주요 고려사항

### 10.1 sq 코드 재사용 가능한 부분

다음은 sq에서 거의 그대로 가져올 수 있다:
- Phase 0 전체 (초기화, 브랜치 생성)
- `wait_wave()` 함수 (Wave 완료 대기)
- `launch_wave_tmux()` / `launch_wave_bg()` (에이전트 실행)
- `run_debate()` 함수
- Phase 3.5 Impact Analysis
- Phase 5 Auto-Fix 구조
- Phase 6 Release Manager (PR 레이블만 "Search Quality Fix"로 변경)
- `timeline_log()`, `auto_commit()` 등 유틸 함수

### 10.2 sq-fix만의 신규 구현 필요 부분

- 최신 리포트 탐색 로직
- Analyst 에이전트 프롬프트
- `fix_targets.json` 스키마 및 파서
- db-fixer 에이전트 프롬프트 (SQL 생성 가이드라인)
- code-fixer 에이전트 프롬프트
- verifier 에이전트 프롬프트 (부분 재검증)
- reporter 에이전트 프롬프트 (before/after 비교)
- Phase 4 게이트 조건 변경

### 10.3 위험 요소 및 대응

| 위험 | 심각도 | 대응 |
|-----|-------|-----|
| DB write 권한 없음 | 🔴 HIGH | sq-setup 확장 또는 마이그레이션 파일 방식 선택 |
| 잘못된 keyword_type 업데이트 | 🟡 MEDIUM | DRY RUN SQL 먼저 출력, Debate 1 검토 |
| 코드 수정 후 prod 검색 악화 | 🔴 HIGH | verifier를 스테이징 API로 검증 후 PR |
| 재검증 대상 키워드 과다 | 🟡 MEDIUM | 최대 200개 cap, 우선순위 순으로 선택 |
| 리포트 없이 실행 | 🟢 LOW | sq 실행 안내 메시지 출력 후 종료 |

### 10.4 구현 순서 권장

1. **Phase 0 + 리포트 탐색 로직** — sq에서 복사 후 리포트 탐색 추가
2. **Analyst 에이전트** — 리포트를 읽고 `fix_targets.json` 생성하는 핵심 로직
3. **db-fixer 에이전트** — MVP: SQL 파일 생성만 (실행은 수동)
4. **verifier 에이전트** — runner + scorer를 부분 실행하는 경량 버전
5. **reporter 에이전트** — before/after 비교 리포트
6. **code-fixer 에이전트** — 가장 복잡, 마지막에 추가
7. **Phase 4 게이트 + Phase 6** — sq에서 수정

---

## 11. 다음 단계

이 설계 문서를 기반으로 실제 `sq-fix` 스크립트를 작성할 때:

1. DB 쓰기 방식 결정 (옵션 A/B/C 중 선택)
2. `sq-fix-design.md` 기반으로 `sq-fix` 스크립트 초안 작성
3. 스테이징 환경에서 db-fixer DRY RUN 테스트
4. 실제 키워드 10~20개 소규모 파일럿 실행
5. 결과 확인 후 전체 적용

---

---

## 부록: danble-backend 검색 핵심 파일 경로

| 파일 | 역할 |
|-----|-----|
| `danble-api/search/services/search_products_service.py` | Tier 1/2 fallback 로직, OpenSearch 쿼리 빌더 |
| `danble-api/search/domains/token_classifier.py` | 엔터티 발골 (BRAND/COLOR/CATEGORY) |
| `danble-api/search/domains/query_analyzer.py` | 쿼리 정규화 + nori 토크나이징 |
| `danble-api/search/repositories/search_keyword_repo.py` | 키워드 Redis 캐시 (TTL 10분) |
| `danble-api/search/models/search_keyword.py` | keyword_type 포함 키워드 사전 모델 |
| `danble-api/search/models/search_keyword_relation.py` | SAME/SIMILAR 관계 모델 |
| `danble-api/search/models/search_brand_keyword.py` | 브랜드 발골 사전 모델 |
| `danble-api/search/models/search_category_keyword.py` | 카테고리 발골 사전 모델 (is_service_midtype 중요) |
| `danble-search/chalicelib/statics/product_index_config.json` | OpenSearch 인덱스 매핑 + analyzer 설정 |

*분석 기반: sq 스크립트 1861줄 + sq-20260430-141805 리포트 (500 키워드) + danble-backend 검색 코드 전체*
