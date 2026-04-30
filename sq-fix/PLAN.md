# sq 수정 + sq-fix 구현 계획서

> 작성일: 2026-04-30  
> 분석 기반: sq 원본 코드(1861줄) · danble-backend 검색 코드 · 실제 DB DDL · sq-20260430-141805 리포트  
> 상태: 구현 전 설계 단계

---

## sq의 목적

> sq는 단순한 품질 측정 도구가 아니다.  
> **백엔드 검색 로직의 문제점을 찾아 코드를 수정하고, 검색 정확도를 높이는 것이 목적이다.**

따라서 sq의 점수 체계는:
- 어떤 백엔드 컴포넌트가 문제인지 **명확히 지목**해야 하고
- 낮은 점수가 **구체적인 수정 방향**으로 이어져야 한다

---

## 목차

1. [현재 시스템 이해 — 검색 파이프라인 전체 그림](#1-현재-시스템-이해)
2. [교차 분석 결과 — sq의 잘못된 가정들](#2-교차-분석-결과)
3. [sq 점수 체계 재설계 (v2)](#3-sq-점수-체계-재설계-v2) ← 핵심
4. [sq 수정 계획](#4-sq-수정-계획)
5. [sq-fix 설계](#5-sq-fix-설계)
6. [DB 스키마 기반 수정 가이드](#6-db-스키마-기반-수정-가이드)
7. [구현 순서 및 우선순위](#7-구현-순서-및-우선순위)

---

## 1. 현재 시스템 이해

### 1-1. 검색 파이프라인 (백엔드 실제 코드 기준)

```
사용자 쿼리 "나이키 데님팬츠"
  │
  ▼
query_analyzer.normalize()          # 특수문자 제거, 소문자, strip
  │
  ▼
query_analyzer.tokenize()           # nori_tokenizer (decompound_mode=none)
  │  → ["나이키", "데님팬츠"]  ← "데님팬츠"는 복합어라도 분리 안 됨
  ▼
token_classifier.classify()
  │  search_keywords 테이블 매칭 → KeywordInfoDTO 생성
  │  search_brand_keywords 조인  → extracted_brands (brand_id 목록)
  │  search_category_keywords 조인 → extracted_category
  │  ※ 브랜드 + 카테고리 동시 매칭 시 → 카테고리 우선, 브랜드 제거
  │  search_keyword_relations 조인 → SAME(동의어) / SIMILAR(유사어)
  ▼
_search_with_fallback()
  │
  ├─ Tier 1: extracted 엔터티로 must 필터 + remaining 토큰으로 should 쿼리
  │          min_score=0.3 적용 (should 쿼리 있을 때)
  │          total_count > 0 이면 → Tier 1 반환
  │
  └─ Tier 2: SIMILAR 유사어까지 포함하여 재검색
             total_count == 0 이어도 → Tier 2 결과 반환
  ▼
product_ids 반환 → ProductQueryFacade.get_product_displays()
  │  is_sold_out 후처리 필터 (OpenSearch 레벨 아님)
  ▼
API 응답
```

### 1-2. 실제 DB 스키마 (DDL 기반)

**검색 관련 핵심 테이블:**

```sql
-- 키워드 사전 (검색의 시작점)
search_keywords (
  id, keyword, keyword_type,      -- BRAND/CATEGORY/COLOR/ETC/STYLE
  category_main,                  -- 카테고리 대분류
  normalized_keyword,             -- 매칭용 정규화 키워드
  converted_keyword,              -- 정규 표기 (예: "니키" → "나이키")
  priority,                       -- 발골 우선순위
  result_product_count,           -- 검색 결과 상품 수
  auto_score, md_score,           -- 자동/MD 점수
  rank, before_rank,              -- 검색어 순위
  is_recommended, allow_rising,
  is_deleted
)

-- 브랜드 발골 사전
search_brand_keywords (
  id, brand_id,                   -- brands 테이블 FK
  search_keyword_id,              -- search_keywords FK
  updated_at
)

-- 카테고리 발골 사전
search_category_keywords (
  id,
  product_type,                   -- "TOP"/"BOTTOM"/"OUTER"/"SHOES"/"BAG"/"ETC"
  search_scope_product_type,      -- 더 넓은 범위의 product_type
  search_scope_product_midtype_ids ARRAY,
  requires_name_search,           -- true면 name 필드 추가 매칭
  name_search_tokens ARRAY,       -- name 검색에 쓸 토큰들
  search_keyword_id,
  product_midtype_ids ARRAY,      -- 서비스 미드타입 ID 목록
  product_subtype_ids ARRAY,
  updated_at
)
-- ⚠️ 중요: DDL에 is_service_midtype 컬럼 없음
--    백엔드 코드가 참조하는 is_service_midtype은 코드 레벨 로직이거나
--    product_midtype_ids가 비어있는지로 판단하는 것으로 추정

-- 동의어 / 유사어
search_keyword_relations (
  id,
  source_keyword_id,              -- search_keywords FK
  target_keyword_id,              -- search_keywords FK
  relation_type,                  -- "SAME"(동의어, Tier1) / "SIMILAR"(유사어, Tier2)
  relation_score,                 -- 유사도 점수
  created_at, updated_at
)

-- 색상 발골 사전
search_color_keywords (
  id, variant_ids ARRAY,          -- 색상 variant ID 목록
  search_keyword_id,
  updated_at
)

-- 상품-키워드 연결
product_display_keywords (
  id, product_display_id,
  search_keyword_ids ARRAY,       -- 연결된 search_keywords
  matchup_keyword_ids ARRAY,
  matchup_keywords ARRAY,
  search_keywords ARRAY,
  created_at, updated_at
)

-- 검색어 순위 (search_keywords에도 중복 저장됨)
search_keyword_rankings (
  id, result_product_count,
  result_style_count, recent_order_count,
  md_score, auto_score,
  rank, before_rank, rank_updated_at,
  search_keyword_id
)
```

**⚠️ DDL vs 코드 불일치 발견:**
- `search_category_keywords`에 `is_service_midtype` 컬럼이 DDL에 없음
- 백엔드 코드(`token_classifier.py`)는 이를 참조하는 듯 보임
- → 실제로는 `product_midtype_ids`가 비어있으면 scope 검색, 있으면 midtype 직접 필터로 분기하는 것으로 추정
- **db-fixer 구현 시 실제 데이터 조회로 확인 필요**

---

## 2. 교차 분석 결과

### sq의 잘못된 가정 목록

#### [A1] 🔴 FALLBACK 감지 기준이 틀렸다

**sq 현재 로직 (scorer 프롬프트):**
```
entity 발골 없음 AND total_count > 1000 → FALLBACK으로 분류 → F등급 강제
```

**실제 백엔드 (`search_products_service.py`):**
```python
tier1_result = _execute_search(use_expanded=False)
if tier1_result["total_count"] > 0:
    return result  # total_count가 몇이든 결과 있으면 정상
# 0이면 Tier 2로 fallback
tier2_result = _execute_search(use_expanded=True)
```

**문제:** 백엔드의 fallback은 결과 수와 무관하다. `total_count > 1000`은 백엔드 어디에도 없는 기준이다. sq가 FALLBACK으로 분류한 36개 키워드 중 상당수는 실제로 정상 Tier 1 결과일 수 있다.

**영향:** 정상 키워드를 F등급으로 잘못 처리 → 리포트 왜곡 → sq-fix가 잘못된 방향으로 수정할 위험

---

#### [A2] 🔴 이중의도(dual intent) 채점이 백엔드 동작과 충돌한다

**sq scorer 가정:**
```
DB에서 category + brand 둘 다 있으면 → 결과에 양쪽 모두 포함되면 +20점
```

**실제 백엔드 (`token_classifier.py`):**
```python
# 동일 토큰이 BRAND + CATEGORY 둘 다 매칭되면 → 브랜드 제거, 카테고리만 사용
extracted_brands = _remove_brands_conflicting_with_category(keywords, extracted_brands_initial)
```

**문제:** 백엔드가 의도적으로 브랜드를 제거하고 OpenSearch에는 카테고리 필터만 전달한다. scorer가 "브랜드 결과가 없다"고 감점하는 것은 백엔드 설계 의도와 정반대다.

**예시:** "로퍼" → category(신발)로 발골됨 → 브랜드 필터 없이 검색 → scorer는 "브랜드 커버리지 없음"으로 감점

---

#### [A3] 🟡 관련성(relevance) 채점이 엔터티 발골 성공 여부와 혼동된다

**sq scorer 가정:**
```
extracted_brands 있음 → relevance_ratio = 1.0 (무조건 만점)
```

**실제 백엔드:**
```python
# 브랜드 발골 성공 = must 필터에 brand_id 추가
# 남은 토큰은 여전히 should 쿼리로 relevance 검색 실행
```

**문제:** "브랜드 발골 성공" ≠ "검색 결과가 관련 있음". 브랜드 필터 내에서도 나머지 토큰의 relevance에 따라 품질이 달라진다. 현재는 발골 성공 시 무조건 만점을 주어 품질 차이를 숨기고 있다.

---

#### [A4] 🟡 ZERO_RESULT의 두 가지 경로를 구분하지 못한다

**백엔드의 실제 흐름:**
```python
# 경로 1: 토큰 분류 자체가 실패 (fallback_tier=0, OpenSearch 호출 없음)
if not keywords and not unmatched and not extracted_brands ...:
    return SearchProductsResult(total_count=0, fallback_tier=0)

# 경로 2: OpenSearch 호출했지만 Tier 1 + Tier 2 모두 결과 없음 (fallback_tier=1 or 2)
```

**문제:** sq scorer는 두 경로를 같은 ZERO_RESULT로 처리한다. 수정 방향이 완전히 다름:
- 경로 1 → 키워드 사전 등록 필요 (search_keywords INSERT)
- 경로 2 → 엔터티 매핑 또는 유사어 추가 필요

---

#### [B1] 🟡 Runner가 보내는 API 파라미터 일부가 백엔드 스키마에 없다

**sq runner:**
```bash
SQ_SEARCH_PARAMS="page=1&limit=50&step=0&search_source=POPULAR_KEYWORD"
```

**백엔드 API 스키마 (`router_search_not_auth.py`):**
```python
class GetSearchProductResultsRequest(Schema):
    query, type_filter, price_filter, brand_filter,
    color_filter, category_filter, sort, page, limit, use_cache
    # ← step, search_source 존재하지 않음
```

**문제:** `step=0`, `search_source=POPULAR_KEYWORD`는 Django Ninja가 조용히 무시한다. sq가 이 파라미터들이 검색에 영향을 준다고 가정하고 있다면 잘못된 가정이다.

---

#### [C1] 🟡 scorer의 FALLBACK 임계값(1000)은 근거 없는 숫자다

`total_count > 1000`의 기준이 된 근거가 코드 어디에도 없다. 실제 서비스에서 FALLBACK이 발생했을 때 total_count가 정확히 얼마인지는 실험이 필요하다.

---

#### [D1] 🟡 백엔드: `_remove_brands_conflicting_with_category()` 문자열 비교가 불안정하다

```python
# token_classifier.py
category_normalized = {
    (kw.converted_keyword or kw.keyword).lower()
    for kw in keywords.values() if kw.keyword_type == "CATEGORY"
}
```

띄어쓰기 variant, 부분 일치를 처리하지 못한다. "롱코트"(카테고리)와 "롱 코트"(브랜드)가 충돌 감지에서 누락될 수 있다.

---

#### [D2] 🟡 백엔드: `is_sold_out`이 OpenSearch 쿼리 레벨에서 필터링되지 않는다

```python
# search_products_service.py
must_filters = [{"term": {"display": True}}]  # is_sold_out 필터 없음
```

품절 상품이 OpenSearch 결과에 포함된다. ProductQueryFacade에서 후처리로 제외되지만, sq scorer는 OpenSearch raw 결과로 채점하므로 품절 상품이 점수에 영향을 준다.

---

#### [D3] 🔵 백엔드: 프로덕션 코드에 `print()` 디버그 로그 잔존

```python
# search_products_service.py line 256
print(f"IDS: {product_ids}")

# token_classifier.py lines 103-109
print(f"extracted_brands: ...")
```

CLAUDE.md 글로벌 규칙 위반 (프로덕션 코드의 console.log 금지). `logger.debug()`로 교체 필요.

---

## 3. sq 점수 체계 재설계 (v2)

> 현재 점수 체계의 문제점(A1~A4, opensearch-analysis.md 분석)을 반영한 전면 재설계.  
> 설계 원칙: **모든 점수는 DB나 API 응답으로 객관적으로 측정되어야 하고, 낮은 점수는 특정 백엔드 수정으로 이어져야 한다.**

---

### 3-1. 점수 체계 전체 구조 (총 100점)

| # | 항목 | 점수 | 측정 방법 | 낮을 때 원인 | 수정 방향 |
|---|-----|-----|---------|-----------|---------|
| 1 | **결과 존재성** | 10점 | `result_count` (API) | 키워드 미등록, 매핑 없음 | `search_keywords` INSERT |
| 2 | **검색 범위 적절성** | 15점 | `result_query.extracted_*` + `total_count` (API) | 엔터티 발골 실패 → 광범위 결과 | 발골 사전 추가 |
| 3 | **의도 파악 정확도** | 20점 | `result_query` 필드 + 실제 결과 상품 속성 | `keyword_type` 오분류, 발골 사전 미등록 | `search_brand/category_keywords` 추가 |
| 4 | **결과 관련성** | 30점 | LLM 평가 (상위 10개 상품) | 쿼리 토크나이징 비활성, 발골 실패, ETC 타입 | 쿼리 로직 개선, 발골 사전 추가 |
| 5 | **상위 노출 품질** | 20점 | 관련 상품의 결과 순위 (API) | ranking 점수 이슈, 광범위 결과 | ranking 로직 조정 |
| 6 | **품절 상품 노출** | 5점 | `product_displays.is_sold_out` (DB) | `is_sold_out` 필터 미적용 | OpenSearch 쿼리 필터 추가 |

**등급 기준 (현재와 동일 유지):**
```
A: 85~100점 / B: 70~84점 / C: 50~69점 / D: 30~49점 / F: 0~29점
```

---

### 3-2. 세그먼트 분류 (채점 전 선행)

점수 채점 전에 세그먼트를 먼저 결정한다. 세그먼트에 따라 채점 방식이 달라진다.

#### STEP 0. ZERO_RESULT 판별

```
result_count = 0 → ZERO_RESULT (점수 0점, 이후 항목 스킵)

단, 원인을 하위 분류:
  result_query의 extracted_brands / extracted_categories / remaining_keyword 모두 비어있음
  → ZERO_UNRECOGNIZED: 쿼리 자체를 인식 못 함 (키워드 사전 미등록)
  → 수정 방향: search_keywords INSERT + 유사어 연결
  
  result_query에 뭔가 있었지만 result_count=0
  → ZERO_NO_MATCH: 인식은 됐지만 조건에 맞는 상품 없음
  → 수정 방향: 매핑 확인 (product_midtype_ids 값 점검) or 유사어 추가
```

#### STEP 1. POSSIBLE_FALLBACK 판별

```
result_query.extracted_brands 비어있음
AND result_query.extracted_categories 비어있음
AND result_query.extracted_colors 비어있음
AND total_count > 2000

→ POSSIBLE_FALLBACK으로 표시 (F등급 강제 아님 — 채점은 계속)
→ 검색 범위 적절성 항목에서 0점 처리
→ diagnosis에 "엔터티 발골 실패 의심 — search_category_keywords 추가 검토" 기록

⚠️ 기존 sq의 total_count > 1000 기준은 코드 근거 없음.
   백엔드 실제 Tier 1/2 fallback은 result_count == 0 기준으로 동작.
   total_count는 참고 지표일 뿐 fallback의 직접 원인이 아님.
```

#### STEP 2. GENERAL 판별

ZERO_RESULT, POSSIBLE_FALLBACK 모두 아니면 → GENERAL로 채점

---

### 3-3. 항목별 상세 채점 기준

---

#### 항목 1. 결과 존재성 (10점)

| result_count | 점수 | 비고 |
|------------|-----|-----|
| 0건 | 0점 | ZERO_RESULT 처리 (이하 모두 0) |
| 1~4건 | 5점 | 결과 극히 적음 — 관련 상품이 실제로 부족할 수 있음 |
| 5~29건 | 8점 | |
| 30건 이상 | 10점 | |

**측정 방법:** API 응답의 `result_count` 또는 `pagination.total_count`

**낮을 때 원인 및 수정 방향:**
```
0건 → ZERO_RESULT 하위 분류로 수정 방향 결정 (STEP 0 참고)
1~4건 → product_displays 테이블에서 해당 카테고리/브랜드 상품 수 확인
         상품 자체가 적은 경우: 수정 불가 (서비스 커버리지 문제)
         상품은 많은데 결과 적은 경우: 쿼리 필드 or 인덱스 누락
```

---

#### 항목 2. 검색 범위 적절성 (15점)

엔터티 발골 성공 여부 + 결과 수로 검색이 얼마나 "좁게" 실행됐는지 평가.

**발골 성공 여부 확인 방법:**
```
API result_query 필드:
  - extracted_brands: 브랜드 발골 결과
  - extracted_categories: 카테고리 발골 결과
  - extracted_colors: 색상 발골 결과
  - remaining_keyword: 발골 후 남은 토큰 (relevance 검색에 사용)
```

**채점표:**

| 조건 | 점수 | 의미 |
|-----|-----|-----|
| extracted_* 중 1개 이상 있음 | 15점 | 엔터티 필터로 좁은 검색 성공 |
| extracted 없음 + total_count ≤ 500 | 10점 | relevance 검색이지만 결과 적절 |
| extracted 없음 + total_count 501~2000 | 5점 | 넓은 결과 — 발골 사전 추가 권장 |
| extracted 없음 + total_count > 2000 | 0점 | POSSIBLE_FALLBACK — 발골 사전 추가 필요 |

**낮을 때 원인 및 수정 방향:**
```
extracted 비어있음 → 두 가지 원인:
  (a) keyword_type = ETC 또는 미등록 → search_brand/category_keywords 추가
  (b) BRAND로 등록됐지만 search_brand_keywords 테이블에 없음 → INSERT 필요
  
total_count > 2000 → search_category_keywords에 카테고리 매핑 추가
  예: "팬츠" → product_type="BOTTOM" 매핑 추가하면 좁은 결과 반환
```

---

#### 항목 3. 의도 파악 정확도 (20점)

백엔드 `token_classifier.py`가 키워드 의도를 얼마나 정확히 파악했는지 평가.

**쿼리 유형 판별 → 유형별 채점:**

```
[유형 A] 브랜드 쿼리 (extracted_brands 있음)
  - DB 조회: SELECT * FROM search_brand_keywords WHERE search_keyword_id = ?
  - 결과 상위 10개 중 해당 brand_id 상품 비율:
    - 80%+ → 20점
    - 60~79% → 15점
    - 40~59% → 10점
    - 20~39% → 5점
    - 20% 미만 → 0점
  ⚠️ 브랜드 + 카테고리 동시 발골 시 백엔드가 카테고리 우선 처리 → 브랜드 유형 아님, 유형 B로

[유형 B] 카테고리 쿼리 (extracted_categories 있음)
  - DB 조회: SELECT * FROM search_category_keywords WHERE search_keyword_id = ?
  - 결과 상위 10개 중 product_type 또는 product_midtype 일치 비율:
    - 80%+ → 20점
    - 60~79% → 15점
    - 40~59% → 10점
    - 20~39% → 5점
    - 20% 미만 → 0점

[유형 C] 색상 쿼리 (extracted_colors 있음, 브랜드/카테고리 없음)
  - 결과 상위 10개 중 해당 색상 상품 비율로 채점 (유형 A/B와 동일 기준)

[유형 D] 복합 쿼리 (추출된 것 여러 개)
  - 각 의도별 충족도 평균 × 20점

[유형 E] ETC 쿼리 (extracted 모두 없음)
  - 이 항목 0점 (항목 4 관련성에서 커버)
  - diagnosis: "keyword_type=ETC 또는 발골 사전 미등록 — 수동 분류 필요"
```

**⚠️ 중요: 문자열 매칭 절대 금지. DB 조회 + 상품 속성으로 판단.**

**낮을 때 원인 및 수정 방향:**
```
유형 A 낮음 → search_brand_keywords의 brand_id 값 확인, 잘못된 브랜드 ID 매핑
유형 B 낮음 → search_category_keywords의 product_midtype_ids 값 확인, 잘못된 카테고리 매핑
ETC 유형 → search_brand_keywords 또는 search_category_keywords에 추가 등록
```

---

#### 항목 4. 결과 관련성 (30점)

상위 10개 상품이 사용자 검색 의도에 실제로 부합하는지 LLM이 평가.

**평가 방식:**
```
1. API 응답에서 상위 10개 상품의 name, brand.label, product_type 추출
2. DB 조회: product_displays에서 is_sold_out, sale_status 확인
3. LLM(에이전트 자신)이 각 상품에 대해:
   "이 상품이 '[키워드]' 검색 결과로 적절한가?" → 적절/부적절 판정
4. 적절한 상품 수 / min(result_count, 10) × 100% = 관련성 비율
5. 관련성 비율 × 30점
```

**판정 시 LLM 가이드라인:**
```
✅ 적절: 키워드가 브랜드명이고 해당 브랜드 상품
✅ 적절: 키워드가 카테고리명이고 해당 카테고리 상품
✅ 적절: 키워드가 소재명이고 해당 소재 상품 (name 필드에서 확인)
✅ 적절: 키워드가 스타일명이고 해당 스타일 상품
❌ 부적절: 관련 없는 브랜드의 전혀 다른 카테고리 상품
❌ 부적절: 키워드와 아무 연관 없이 단순히 display=true인 상품
⚠️ 판단 불가: name, brand 정보만으로 판단 어려울 때 → 적절로 처리 (보수적)
```

**⚠️ 절대 금지:**
```
- 단순 문자열 포함 여부로 관련성 판단 금지
  예: "나이키" 검색 → name에 "나이키" 포함되면 관련성 있다고 판단 X
  이유: 인덱스 검색은 형태소 분석 기반이라 문자열 포함 ≠ 검색 결과 기준
- Python/Shell 스크립트 생성 금지 (scorer 에이전트가 직접 판단)
```

**낮을 때 원인 및 수정 방향:**
```
관련성 < 60% → 두 가지 원인 구분 필요:
  (a) 발골 실패 (ETC 타입) → 항목 3에서 이미 0점 → 발골 사전 추가가 근본 해결
  (b) 발골 성공했는데도 관련성 낮음 → OpenSearch 쿼리 로직 문제:
      - decompound_mode=none으로 복합어 분리 안 됨 → 유사어 추가
      - 쿼리 토크나이징 비활성 (주석 처리된 코드) → 활성화 검토
      - min_score=0.3이 너무 낮아 무관한 상품 포함 → 임계값 상향 검토
```

---

#### 항목 5. 상위 노출 품질 (20점)

관련성 있는 상품 중 가장 높은 순위의 상품이 얼마나 앞에 있는가.

**채점 기준:**
```
관련성 있는 상품의 최고 순위 위치:
  1~2위  → 20점 (최고 관련 상품이 바로 눈에 띔)
  3~5위  → 15점
  6~10위 → 8점
  11~20위→ 3점
  21위+  → 0점
  관련 상품 없음 (항목 4 = 0%) → 0점
```

**낮을 때 원인 및 수정 방향:**
```
관련 상품이 있는데 하위 노출 → ranking 점수 이슈:
  - product_scoring_tags / product_scorings 테이블의 scoring 값 확인
  - scores.ranking이 관련성과 무관하게 정렬되고 있을 가능성
  - 특히 POSSIBLE_FALLBACK 키워드는 엔터티 필터 없이 must 조건이 약해서
    ranking이 높은 무관 상품이 상위에 올 수 있음
```

---

#### 항목 6. 품절 상품 노출 (5점)

**⚠️ 가중치를 기존 15점 → 5점으로 낮춘 이유:**
- 이건 OpenSearch 쿼리에 `{"term": {"is_sold_out": False}}` 한 줄 추가로 해결되는 인프라 이슈
- 검색 알고리즘 로직의 정확도와는 별개의 문제
- sq의 주목적(알고리즘 정확도 개선)보다 우선순위가 낮음

**채점 기준:**
DB에서 상위 10개 product_display_id로 `product_displays.is_sold_out` 조회:

| 품절 비율 | 점수 |
|---------|-----|
| 0% | 5점 |
| 1~10% | 4점 |
| 11~30% | 2점 |
| 31%+ | 0점 |

**측정 방법:**
```sql
SELECT COUNT(*) FILTER (WHERE is_sold_out = true) * 100.0 / COUNT(*)
FROM product_displays
WHERE id = ANY(ARRAY[{상위 10개 product_display_id}])
```

---

### 3-4. 진단(Diagnosis) 체계

점수와 별도로 각 키워드에 진단 레이블을 부여. sq-fix의 Analyst가 이 레이블을 기반으로 수정 액션을 결정한다.

| 진단 코드 | 조건 | 수정 액션 |
|---------|-----|---------|
| `ZERO_UNRECOGNIZED` | result_count=0 + extracted 모두 비어있음 | `search_keywords` INSERT |
| `ZERO_NO_MATCH` | result_count=0 + extracted 있었음 | 매핑 확인 or 유사어 추가 |
| `POSSIBLE_FALLBACK` | extracted 없음 + total_count>2000 | `search_category_keywords` INSERT |
| `ETC_TYPE` | keyword_type=ETC + result_count>0 + 관련성<60% | `keyword_type` UPDATE + 발골 사전 추가 |
| `BRAND_MAPPING_WRONG` | 의도파악<50% (브랜드 유형) | `search_brand_keywords.brand_id` 확인 |
| `CATEGORY_MAPPING_WRONG` | 의도파악<50% (카테고리 유형) | `search_category_keywords` 값 확인 |
| `LOW_RELEVANCE` | 관련성<40% + 발골 성공 | 쿼리 토크나이징 활성화, min_score 조정 |
| `POOR_RANKING` | 관련성>60% + 상위노출<8점 | ranking 점수 로직 검토 |
| `NO_SYNONYM` | A등급인데 relation 0개 | `search_keyword_relations` INSERT (안전망) |
| `SOLDOUT_EXPOSED` | 품절 비율>30% | `is_sold_out` OpenSearch 필터 추가 |
| `SPACING_VARIANT` | 붙여쓰기/띄어쓰기 동일 키워드 점수 차이 >20점 | `search_keyword_relations` SAME 추가 |

---

### 3-5. 현재(v1) vs 새로운(v2) 비교표

| 항목 | v1 (현재) | v2 (개선) | 변경 이유 |
|-----|---------|---------|---------|
| 결과 존재 | 20점 | 10점 | 가중치 재분배 |
| FALLBACK 감지 | total_count>1000 → F강제 | extracted 없음 + total_count>2000 → 항목 2에서 0점 (F강제 아님) | A1: 백엔드 코드에 근거 없는 기준 수정 |
| 이중의도 | category+brand 둘 다 있어야 | 유형별 채점 (브랜드 OR 카테고리 각각 평가) | A2: 백엔드의 카테고리 우선 처리 반영 |
| 관련성 | extracted_brands 있으면 무조건 1.0 | LLM 독립 평가 (발골과 분리) | A3: 발골 성공 ≠ 검색 품질 |
| ZERO_RESULT | 단순 0건 처리 | UNRECOGNIZED vs NO_MATCH 구분 | A4: 수정 방향이 다름 |
| 상위 노출 | 15점 | 20점 | 가중치 상향 (사용자 경험에 직결) |
| 품절 | 15점 | 5점 | 알고리즘 정확도와 분리, 인프라 이슈 |
| 검색 범위 | 없음 | 15점 (신규) | 발골 성공 여부를 명시적으로 측정 |
| 의도 파악 | 이중의도 20점 | 의도 파악 정확도 20점 | 재정의 |
| **합계** | **100점** | **100점** | |

---

### 3-6. 점수별 수정 우선순위 가이드

sq 리포트를 받은 sq-fix Analyst가 어떤 키워드부터 수정해야 하는지 결정하는 기준:

```
우선순위 1 (즉시 수정, 높은 효과):
  - ZERO_UNRECOGNIZED: SQL INSERT 한 줄로 점수 0 → 70+ 가능
  - POSSIBLE_FALLBACK: 카테고리 매핑 추가로 광범위 결과 → 좁은 결과 전환
  - ETC_TYPE (result_count 많음): 발골 사전 추가로 의도 파악 0 → 20점

우선순위 2 (수정 권장, 중간 효과):
  - ZERO_NO_MATCH: 매핑 수정 또는 유사어 추가
  - BRAND/CATEGORY_MAPPING_WRONG: 잘못된 ID 수정
  - SPACING_VARIANT: 동의어 추가

우선순위 3 (검토 필요, 코드 수정):
  - LOW_RELEVANCE: 쿼리 토크나이징 활성화, min_score 조정
  - POOR_RANKING: ranking 점수 로직 검토
  - SOLDOUT_EXPOSED: is_sold_out 필터 추가

보류 (서비스 정책 결정 필요):
  - result_count 1~4건인데 관련 상품 자체가 없는 경우 → 상품 구성 문제
```

---

## 4. sq 수정 계획

### 4-1. 수정 우선순위

| 항목 | 심각도 | 영향 범위 | 수정 난이도 |
|-----|-------|---------|----------|
| A1: FALLBACK 감지 기준 수정 | 🔴 HIGH | 리포트 정확도 전체 | 중 |
| A2: dual intent 채점 로직 수정 | 🔴 HIGH | 채점 공정성 | 중 |
| B1: 불필요한 API 파라미터 정리 | 🟡 MEDIUM | runner 명확성 | 낮음 |
| A3: relevance 채점 개선 | 🟡 MEDIUM | 점수 정밀도 | 높음 |
| A4: ZERO_RESULT 경로 구분 | 🟡 MEDIUM | 진단 정확도 | 중 |
| C1: FALLBACK 임계값 근거 마련 | 🟡 MEDIUM | 채점 신뢰성 | 낮음 |

---

### 4-2. A1 수정: FALLBACK 감지 기준 재정의

**현재 (sq scorer 프롬프트 lines 917-928):**
```
extracted_brands/colors/categories 모두 비어있음 AND total_count > 1000 → FALLBACK
```

**수정안:**

실제 백엔드가 fallback을 API response에 노출하지 않으므로, 현실적인 대안은:

**Option 1 (권장): API response의 `result_query` 필드 활용**
```
result_query.extracted_brands 비어있음
AND result_query.extracted_colors 비어있음  
AND result_query.extracted_categories 비어있음
AND total_count > 500  ← 임계값 낮춤 (기존 1000보다 보수적)
→ POSSIBLE_FALLBACK으로 표시 (F등급 강제 대신 진단 항목으로)
```

**Option 2 (근본 해결): 백엔드에 fallback_tier 노출 요청**
```python
# router_search_not_auth.py response에 추가:
"fallback_tier": service_result.fallback_tier  # 0=조기반환, 1=Tier1, 2=Tier2
```
→ sq runner가 이 값을 수집하면 정확한 분류 가능

**수정할 sq 코드 위치:** scorer 프롬프트 STEP 0 (lines 912-935)

```bash
# 수정 전
if total_count > 1000 → FALLBACK

# 수정 후
if result_query.extracted_* 모두 비어있음 AND total_count > 500:
  segment = "POSSIBLE_FALLBACK"  # F등급 강제 아님
  diagnosis에 "엔터티 발골 실패 의심 — 수동 확인 필요" 추가
  점수는 정상 채점 계속 진행 (ZERO_RESULT 아니므로)
```

---

### 4-3. A2 수정: dual intent 채점 기준 정정

**현재 (sq scorer STEP 3.3):**
```
DB에 category + brand 둘 다 있으면 → 결과에 양쪽 있어야 만점
```

**수정안:**
백엔드가 "브랜드-카테고리 충돌 시 카테고리 우선"을 의도적 설계로 구현했으므로, dual intent 채점을 현실에 맞게 변경:

```
케이스 A: category만 발골 (brand 없음 or 제거됨)
  → "카테고리 의도 충족 여부"만 평가 (20점 만점)

케이스 B: brand만 발골
  → "브랜드 의도 충족 여부"만 평가 (20점 만점)

케이스 C: brand + category 독립적으로 발골 (충돌 없이 공존)
  → 기존처럼 양쪽 커버리지 평가 (각 10점)

케이스 D: keyword_type=ETC (발골 없음)
  → 검색 의도 불명확 → 20점 중 의도 파악 가능 범위 내에서 채점
```

**수정할 sq 코드 위치:** scorer 프롬프트 STEP 3.3 (lines 1038-1047)

---

### 4-4. B1 수정: runner API 파라미터 정리

**현재:**
```bash
SQ_SEARCH_PARAMS="page=1&limit=50&step=0&search_source=POPULAR_KEYWORD"
```

**수정안:**
```bash
SQ_SEARCH_PARAMS="page=1&limit=50"
# step, search_source 제거 — 백엔드 스키마에 없는 파라미터
```

**수정할 sq 코드 위치:** 스크립트 상단 변수 정의 (line ~89)

---

### 4-5. A4 수정: ZERO_RESULT 경로 구분 진단

현재 sq는 result_count=0을 모두 동일하게 처리한다. 진단 정확도를 높이기 위해:

```
ZERO_RESULT 키워드를 하위 분류:

result_query의 extracted_* + keywords 모두 비어있음
  → ZERO_RESULT_UNRECOGNIZED (키워드 사전 미등록)
  → 수정 방향: search_keywords 테이블 INSERT

result_query에 뭔가 있었지만 결과 0
  → ZERO_RESULT_NO_MATCH (매핑은 됐지만 상품 없음)
  → 수정 방향: entity 매핑 조정 or 유사어 추가
```

**수정할 sq 코드 위치:** scorer 프롬프트 STEP 1 (lines 939-944)

---

## 5. sq-fix 설계

### 4-1. 포지셔닝

```
sq     → "현재 검색 품질이 어떤가?" 를 측정
sq-fix → "측정된 문제를 실제로 고친다"
```

- sq가 생성한 최신 리포트를 인풋으로 받아 자동 실행
- 코드·DB 수정 후 수정된 키워드만 재검증
- sq와 동일한 Phase 구조, 다른 에이전트 역할

---

### 4-2. 실행 플로우

```
sq-fix [리포트경로?]
  │
  ▼ Phase 0: 초기화 (sq와 동일)
  │  - 최신 sq 리포트 자동 탐색 (sq-fix 리포트 제외)
  │  - 브랜치 생성: sq-fix/{slug}-{TIMESTAMP}
  │  - 작업 디렉토리: .agent/sq-fix-{TIMESTAMP}/
  │  - 출력 디렉토리: docs/reports/sq-fix-{TIMESTAMP}/
  ▼
  Phase 1: Analyst
  │  - 리포트 3종 읽기 (report.md + detail.md + detail.csv)
  │  - 문제 분류 → fix_targets.json 생성
  │  - 에이전트 선택 (db-fixer / code-fixer 필요 여부 결정)
  │  - analysis.md + agents.txt + commit_msg.txt 생성
  ▼
  Debate 1: 수정 계획 검토 (Red/Blue/Judge)
  ▼
  Wave A (병렬):
  │  ├── db-fixer: SQL DRY RUN → 승인 → 실행
  │  └── code-fixer: 코드 수정 (print 제거, OpenSearch 쿼리 개선)
  │       ← 필요 시에만 실행 (Analyst 판단)
  ▼
  Wave B (순차):
  │  └── verifier: 수정된 키워드만 재검색 + 재채점
  ▼
  Wave C (순차):
  │  └── reporter: before/after 비교 리포트 생성
  ▼
  Debate 2: 결과 검토 (REWORK 가능)
  ▼
  Phase 3.5: 영향도 분석
  ▼
  Phase 4: 검증 게이트
  ▼
  Phase 5: 자동 수정 (실패 시, 최대 2라운드)
  ▼
  Phase 6: Release Manager → PR 생성
```

---

### 4-3. 에이전트 상세 설계

#### Phase 1: Analyst

**역할:** 최신 sq 리포트를 읽고 수정 대상을 분류, 에이전트 지시서 작성

**입력:**
- `docs/reports/sq-{LATEST}/search-quality-report.md`
- `docs/reports/sq-{LATEST}/search-quality-detail.csv`
- `docs/reports/sq-{LATEST}/search-quality-detail.md`

**분류 기준 (교차 분석 결과 반영):**

| 문제 유형 | 감지 방법 | 수정 대상 | 난이도 |
|---------|---------|---------|-----|
| `ETC_TYPE` | keyword_type=ETC + 결과 있음 + 낮은 점수 | search_keywords.keyword_type UPDATE + search_brand/category_keywords INSERT | 중 |
| `ZERO_UNRECOGNIZED` | result_count=0 + extracted_* 모두 비어있음 | search_keywords INSERT | 낮음 |
| `ZERO_NO_MATCH` | result_count=0 + extracted_* 있음 | search_keyword_relations INSERT (유사어) | 중 |
| `POSSIBLE_FALLBACK` | extracted_* 비어있음 + total_count>500 | search_category_keywords INSERT | 중 |
| `DUAL_INTENT_GAP` | brand 있는데 category 매핑 없음 | search_category_keywords INSERT | 낮음 |
| `NO_SYNONYM` | A등급인데 relation 0개 | search_keyword_relations INSERT | 낮음 |
| `SPACING_VARIANT` | 붙여쓰기와 띄어쓰기 점수 차이 큼 | search_keyword_relations SAME 추가 | 낮음 |

**출력:**
```
${FLAG_DIR}/analysis.md          # 문제 분류 및 수정 우선순위
${FLAG_DIR}/fix_targets.json     # 수정 액션 목록 (아래 스키마 참고)
${FLAG_DIR}/code_issues.md       # 코드 수정 필요 항목
${FLAG_DIR}/agents.txt           # db-fixer / code-fixer 선택
${FLAG_DIR}/commit_msg.txt       # 커밋 메시지
```

**fix_targets.json 스키마:**
```json
[
  {
    "keyword": "아미",
    "issue_type": "ETC_TYPE",
    "current_type": "ETC",
    "target_type": "BRAND",
    "action": "UPDATE_KEYWORD_TYPE",
    "also_add_brand_mapping": true,
    "brand_id": null,
    "priority": 1,
    "expected_score_gain": 15,
    "evidence": "result_count=394, score=35, relevance=0%"
  },
  {
    "keyword": "양털자켓",
    "issue_type": "ZERO_UNRECOGNIZED",
    "action": "INSERT_KEYWORD",
    "new_keyword_type": "ITEM",
    "synonyms_to_add": ["플리스자켓", "후리스자켓"],
    "priority": 2,
    "expected_score_gain": 20,
    "evidence": "result_count=0, extracted_all_empty"
  },
  {
    "keyword": "팬츠",
    "issue_type": "POSSIBLE_FALLBACK",
    "action": "ADD_CATEGORY_MAPPING",
    "product_type": "BOTTOM",
    "product_midtype_ids": [],
    "requires_name_search": false,
    "priority": 1,
    "expected_score_gain": 20,
    "evidence": "total_count=10000, no_category_extracted"
  }
]
```

---

#### Wave A-1: db-fixer

**역할:** `fix_targets.json` 기반으로 SQL 생성 → DRY RUN 출력 → 실행

**작업 순서:**

1. **DRY RUN 모드**: 실행 예정 SQL을 `db_fix_plan.sql`에 저장, 내용 출력
2. **검증**: SQL 내 참조 ID(brand_id, product_midtype_ids 등) 실제 존재 여부 확인
3. **실행**: 트랜잭션으로 묶어 실행
4. **결과 기록**: 변경 행수를 `db_fix_result.json`에 저장

**DB 수정 작업별 SQL 패턴:**

```sql
-- 1. keyword_type 업데이트
UPDATE search_keywords
SET keyword_type = 'BRAND', updated_at = NOW()
WHERE keyword = '아미'
  AND keyword_type = 'ETC'
  AND is_deleted = false;

-- 2. 브랜드 발골 사전 추가
INSERT INTO search_brand_keywords (brand_id, search_keyword_id, updated_at)
SELECT {brand_id}, sk.id, NOW()
FROM search_keywords sk
WHERE sk.keyword = '아미'
  AND NOT EXISTS (
    SELECT 1 FROM search_brand_keywords sbk WHERE sbk.search_keyword_id = sk.id
  );

-- 3. 미등록 키워드 추가
INSERT INTO search_keywords (
  keyword, keyword_type, category_main, priority,
  result_product_count, result_style_count,
  auto_score, md_score, recent_order_count,
  is_deleted, is_recommended, allow_rising,
  created_at, updated_at
)
VALUES ('양털자켓', 'ITEM', '', 50, 0, 0, 0, 0, 0, false, false, false, NOW(), NOW())
ON CONFLICT (keyword) DO NOTHING;

-- 4. 카테고리 발골 사전 추가
INSERT INTO search_category_keywords (
  product_type, search_scope_product_type,
  requires_name_search, name_search_tokens,
  product_midtype_ids, product_subtype_ids,
  search_keyword_id, updated_at
)
SELECT 'BOTTOM', 'BOTTOM', false, '{}', '{}', '{}', sk.id, NOW()
FROM search_keywords sk
WHERE sk.keyword = '팬츠'
  AND NOT EXISTS (
    SELECT 1 FROM search_category_keywords sck WHERE sck.search_keyword_id = sk.id
  );

-- 5. 동의어/유사어 추가
INSERT INTO search_keyword_relations (
  source_keyword_id, target_keyword_id,
  relation_type, relation_score, created_at, updated_at
)
SELECT src.id, tgt.id, 'SAME', 1.0, NOW(), NOW()
FROM search_keywords src, search_keywords tgt
WHERE src.keyword = '양털자켓'
  AND tgt.keyword = '플리스자켓'
  AND NOT EXISTS (
    SELECT 1 FROM search_keyword_relations r
    WHERE r.source_keyword_id = src.id AND r.target_keyword_id = tgt.id
  );
```

**출력:**
```
${FLAG_DIR}/db_fix_plan.sql      # DRY RUN SQL
${FLAG_DIR}/db_fix_result.json   # 실행 결과 (변경 행수 포함)
${FLAG_DIR}/db-fixer.done
```

**⚠️ DB 쓰기 권한 선결 과제:**
현재 sq는 `danble_read_only` 계정만 있다. 아래 중 하나 선택 필요:

- **옵션 A (MVP):** SQL 파일 생성만 → 개발자가 수동 실행 (안전, 리뷰 가능)
- **옵션 B:** `sq-setup`에 write 계정 추가 (`~/.config/sq/db.env`에 `PGUSER_WRITE`, `PGPASSWORD_WRITE`)
- **옵션 C:** Django management command 또는 마이그레이션으로 생성

**MVP는 옵션 A 권장** — SQL 파일을 PR에 포함시키면 리뷰 + 버전 관리 동시에 된다.

---

#### Wave A-2: code-fixer (선택적 실행)

**역할:** Analyst가 코드 수정 필요라고 판단한 경우에만 실행

**수정 대상 파일 (경로 확정):**
```
danble-api/search/services/search_products_service.py
  → line 256: print(f"IDS: {product_ids}") → logger.debug()로 교체

danble-api/search/domains/token_classifier.py  
  → lines 103-109: print 문 → logger.debug()로 교체

danble-search/chalicelib/statics/product_index_config.json
  → synonym filter 추가 (스페이싱 variant 처리)
```

**synonym filter 추가 예시 (`product_index_config.json`):**
```json
{
  "filter": {
    "danble_synonym_filter": {
      "type": "synonym",
      "synonyms": [
        "내셔널지오그래피, 내셔널 지오그래피",
        "블랙멜란지, 블랙 멜란지",
        "빈티지블랙, 빈티지 블랙"
      ]
    }
  }
}
```

**출력:**
```
${FLAG_DIR}/code_fix_summary.md   # 변경 내역
${FLAG_DIR}/code-fixer.done
```

---

#### Wave B: verifier

**역할:** 수정된 키워드만 재검색 + 재채점 (전체 500개 재실행 아님)

**핵심 원칙:** sq의 runner + scorer와 동일한 로직 사용, 대상 키워드만 축소

**실행 방식:**
1. `db_fix_result.json`에서 수정된 키워드 추출
2. `code_fix_summary.md`에서 영향받는 키워드 추출  
3. 합집합 → 최대 200개로 cap (우선순위 높은 것부터)
4. 검색 API 호출 (sq runner와 동일한 방식)
5. sq scorer와 동일한 100점 기준으로 재채점
6. before 점수와 비교 (detail.csv에서 읽음)

**⚠️ 검증 환경 주의사항:**
- DB 수정이 옵션 A(SQL 파일만)로 실행된 경우 → verifier가 의미 없음 (DB 미반영)
- DB 수정이 실제 실행된 경우 → 검색 캐시 TTL 10분 대기 필요 (SearchKeywordRepo Redis 캐시)

**출력:**
```
/tmp/sq-fix/{keyword}.json        # 재검증 결과 JSON
${FLAG_DIR}/verify_scores.json    # 재채점 결과
${FLAG_DIR}/verifier.done
```

---

#### Wave C: reporter

**역할:** before/after 비교 리포트 3종 생성

**입력:**
- `docs/reports/sq-{LATEST}/search-quality-detail.csv` (before)
- `${FLAG_DIR}/verify_scores.json` (after)
- `${FLAG_DIR}/db_fix_result.json`
- `${FLAG_DIR}/code_fix_summary.md`

**출력 (`docs/reports/sq-fix-{TIMESTAMP}/`):**
```
fix-summary-report.md    # 경영진 요약
fix-detail.md            # 키워드별 before/after 테이블
fix-detail.csv           # 전체 데이터 (before/after 컬럼 포함)
```

**fix-summary-report.md 구조:**
```markdown
## 수정 요약
- DB 수정: N건 (keyword_type 업데이트: A건, 신규 키워드: B건, 카테고리 매핑: C건, 동의어: D건)
- 코드 수정: N파일

## 검증 결과 (수정된 키워드 N개 기준)
- 평균 점수: XX → XX (+XX)
- FALLBACK → GENERAL 전환: N개
- ZERO_RESULT → GENERAL 전환: N개
- 등급 상승: N개 (D→A: N, D→B: N, D→C: N, C→A: N, C→B: N)
- 등급 하락 (주의): N개

## 상위 개선 키워드 Top 10
| 키워드 | Before | After | 상승폭 |
...

## 주의 필요 키워드 (점수 하락)
...
```

---

### 4-4. Phase 4 검증 게이트

| # | 조건 | 통과 기준 |
|---|-----|---------|
| 1 | db_fix_result.json 존재 | 파일 있음 (수정 건수 0이어도 통과, 단 이유 기록) |
| 2 | verify_scores.json | 파일 있음 + 채점 완료 + 키워드 수 ≥ 1 |
| 3 | 리포트 3파일 | fix-summary + fix-detail.md + fix-detail.csv 모두 존재 |
| 4 | 점수 개선 확인 | 재검증 키워드 평균 점수 ≥ before 평균 (개악 아님 확인) |

---

### 4-5. 리포트 자동 탐색 로직

```bash
# sq-fix 리포트 폴더 탐색 (sq-fix-* 폴더는 제외)
REPORTS_DIR="$(pwd)/docs/reports"
LATEST_SQ_REPORT=$(ls -dt "${REPORTS_DIR}"/sq-[0-9]* 2>/dev/null | head -1)

if [[ -z "$LATEST_SQ_REPORT" ]]; then
  echo "❌ sq 리포트를 찾을 수 없습니다."
  echo "   먼저 sq를 실행하세요: sq"
  exit 1
fi

echo "📋 기반 리포트: ${LATEST_SQ_REPORT}"
```

**명시적 지정 지원:**
```bash
sq-fix                                        # 최신 자동 탐색
sq-fix docs/reports/sq-20260430-141805        # 특정 리포트
sq-fix --only db                              # DB 수정만
sq-fix --only code                            # 코드 수정만
sq-fix --dry-run                              # SQL 생성만, 실행 안 함
```

---

### 4-6. 파일 구조

```
.agent/sq-fix-{TIMESTAMP}/
├── TIMELINE.md
├── analysis.md                   # Analyst 결과
├── fix_targets.json              # 수정 대상 목록
├── code_issues.md                # 코드 수정 목록
├── agents.txt                    # 선택된 에이전트
├── commit_msg.txt
├── prompt_{N}.txt / run_{N}_{agent}.sh
├── db-fixer.done / code-fixer.done / verifier.done
├── db_fix_plan.sql               # DRY RUN SQL (항상 생성)
├── db_fix_result.json            # 실행 결과
├── code_fix_summary.md
├── verify_scores.json
├── debate_design_verdict.txt
├── debate_review_verdict.txt
├── impact_analysis.md
├── release_report.md
├── SUMMARY.md
└── analyst.log / db-fixer.log / code-fixer.log / verifier.log / reporter.log

docs/reports/sq-fix-{TIMESTAMP}/
├── fix-summary-report.md
├── fix-detail.md
└── fix-detail.csv
```

---

## 6. DB 스키마 기반 수정 가이드

### 5-1. DDL에서 확인된 실제 컬럼 목록

**search_category_keywords 실제 컬럼 (DDL 기준):**
```sql
id, product_type, search_scope_product_type,
search_scope_product_midtype_ids ARRAY,
requires_name_search, name_search_tokens ARRAY,
search_keyword_id, product_midtype_ids ARRAY,
product_subtype_ids ARRAY, updated_at
```
→ `is_service_midtype` 컬럼 없음. 백엔드 코드의 분기는 `product_midtype_ids`가 비어있는지로 판단하는 것으로 추정.

**search_keywords 실제 컬럼 (DDL 기준):**
```sql
id, keyword, keyword_type, category_main,
normalized_keyword, converted_keyword, priority,
result_product_count, result_style_count,
auto_score, md_score, recent_order_count,
rank, before_rank, rank_updated_at,
is_recommended, allow_rising, is_deleted,
created_at, updated_at
```

### 5-2. 문제 유형별 SQL 작업 매핑

| 문제 유형 | 대상 테이블 | 작업 |
|---------|-----------|-----|
| ETC_TYPE | search_keywords | UPDATE keyword_type |
| ETC_TYPE (브랜드) | search_brand_keywords | INSERT |
| ETC_TYPE (카테고리) | search_category_keywords | INSERT |
| ZERO_UNRECOGNIZED | search_keywords | INSERT |
| ZERO_UNRECOGNIZED (유사어) | search_keyword_relations | INSERT (SIMILAR) |
| POSSIBLE_FALLBACK | search_category_keywords | INSERT |
| DUAL_INTENT_GAP | search_category_keywords | INSERT |
| NO_SYNONYM | search_keyword_relations | INSERT (SAME or SIMILAR) |
| SPACING_VARIANT | search_keyword_relations | INSERT (SAME) |

### 5-3. product_midtype_ids 값 확인 방법

db-fixer가 카테고리 매핑 추가 시, 실제 `variants` 테이블의 ID를 조회해야 한다:

```sql
-- product_type별 midtype 목록 조회
SELECT v.id, v.variant_type, v.value, v.display_name
FROM variants v
WHERE v.variant_type = 'product_midtype'
  AND v.is_deleted = false
ORDER BY v.value;
```

---

## 7. 구현 순서 및 우선순위

### Phase 1: sq 버그 수정 (선행)

sq-fix 구현 전에 sq 자체의 잘못된 가정을 먼저 수정해야 sq-fix 결과물이 신뢰할 수 있다.

1. **B1 수정** (30분) — API 파라미터 정리 (`step`, `search_source` 제거)
2. **A1 수정** (2~3시간) — FALLBACK 감지 기준 재정의
3. **A2 수정** (2~3시간) — dual intent 채점 로직 수정
4. **A4 수정** (1~2시간) — ZERO_RESULT 경로 구분 진단 추가

### Phase 2: sq-fix MVP (DB 수정 중심)

DB 쓰기 방식을 옵션 A(SQL 파일 생성)로 시작.

1. Phase 0 + 리포트 탐색 로직 — sq 코드에서 복사 + 변경 (1일)
2. Analyst 에이전트 — fix_targets.json 생성 (1~2일)
3. db-fixer 에이전트 — SQL DRY RUN 생성 (1~2일)
4. verifier 에이전트 — 부분 재검증 (1일)
5. reporter 에이전트 — before/after 비교 (1일)
6. Phase 4 게이트 + Phase 6 Release Manager (반일)

### Phase 3: sq-fix 고도화 (코드 수정 포함)

1. code-fixer 에이전트 추가
2. DB 직접 실행 (옵션 B — sq-setup에 write 계정 추가)
3. verifier에 Redis 캐시 TTL 대기 로직 추가

---

## 부록: sq/sq-fix 수정 시 건드리는 파일 전체 목록

### sq 수정 파일
```
~/development/tmux/sq/sq   # 스크립트 본체 (1861줄)
  - line ~89: SQ_SEARCH_PARAMS (B1)
  - lines 912-935: scorer STEP 0 — FALLBACK 감지 (A1)
  - lines 939-944: scorer STEP 1 — ZERO_RESULT 분류 (A4)
  - lines 1038-1047: scorer STEP 3.3 — dual intent 채점 (A2)
```

### sq-fix 신규 파일
```
~/development/tmux/sq-fix/sq-fix   # 새로 작성할 스크립트
~/development/tmux/sq-fix/PLAN.md  # 이 문서
```

### 백엔드 코드 수정 파일 (code-fixer 대상)
```
danble-api/search/services/search_products_service.py   # print 제거
danble-api/search/domains/token_classifier.py           # print 제거
danble-search/chalicelib/statics/product_index_config.json  # synonym filter
```

### DB 수정 대상 테이블
```
search_keywords                # keyword_type 업데이트, 신규 INSERT
search_brand_keywords          # 브랜드 발골 사전 추가
search_category_keywords       # 카테고리 발골 사전 추가
search_keyword_relations       # 동의어/유사어 추가
```

---

*이 문서는 sq 스크립트(1861줄) + danble-backend 검색 코드 + 실제 DB DDL + sq-20260430-141805 리포트 교차 분석 결과를 기반으로 작성되었습니다.*
