# Danble 검색 파이프라인 — 완전 분석

> 작성일: 2026-05-04  
> 분석 대상: `danble-api/search/` 전체  
> 참고: `sq-opensearch-logic.md`

---

## 1. 전체 아키텍처

```
클라이언트 (iOS / Android / Web)
    │  GET /api/v1/search/product-results?query=청바지&page=1&limit=50
    ▼
┌─────────────────────────────────────────────────────────────────┐
│  SearchProductsService.search_products(query)                    │
│                                                                   │
│  ① QueryAnalyzer.normalize()      소문자 + 특수문자 제거          │
│  ② _tokenize_with_opensearch()    형태소 분석 (nori tokenizer)   │
│  ③ TokenClassifier.classify()     키워드 발골 (BRAND/COLOR/CAT)  │
│  ④ ZERO_UNRECOGNIZED 검사          전부 없으면 즉시 빈 결과       │
│  ⑤ _search_with_fallback()        Tier1 → Tier2 검색             │
└─────────────────────────────────────────────────────────────────┘
         │                               │
         ▼                               ▼
┌─────────────────┐           ┌────────────────────────────┐
│  PostgreSQL DB  │           │  AWS OpenSearch             │
│                 │           │  (index: products)          │
│  search_keywords│──────────▶│  _analyze API (토크나이징)   │
│  search_keyword │           │  _search  API (검색)        │
│  _relations     │           │                             │
│  search_brand_  │           │  analyzer: nori             │
│  keywords       │           │  decompound_mode: none      │
│  search_color_  │           │  (복합어 미분해)              │
│  keywords       │           └────────────────────────────┘
│  search_category│
│  _keywords      │
└─────────────────┘
```

---

## 2. 단계별 상세 흐름

### ① QueryAnalyzer.normalize(query)

```python
# search/domains/query_analyzer.py
def _normalize(self, query: str) -> str:
    query = re.sub(r"[^\w\s]", "", query)  # 특수문자 제거
    return query.lower().strip()
```

- 예: `"ZARA 청바지!"` → `"zara 청바지"`

---

### ② _tokenize_with_opensearch(normalized_query)

```python
result = opensearch_plugin.tokenize(index="products", text=query)
tokens = [token["token"] for token in result["tokens"]]
# 실패 시 폴백: query.split()
```

| 항목 | 내용 |
|------|------|
| 분석기 | nori (한국어 형태소 분석기) |
| `decompound_mode` | `none` — **복합어를 분해하지 않음** |
| 실패 시 | 공백 분리 토크나이저로 폴백 |

**decompound_mode=none 영향:**

| 입력 | 결과 | 의미 |
|------|------|------|
| "린넨셔츠" | `["린넨셔츠"]` | 사전에 복합어 전체 등록 필요 |
| "맨투맨후드티" | `["맨투맨후드티"]` | 개별 토큰 매칭 불가 |
| "자라 청바지" | `["자라", "청바지"]` | 공백 기준 정상 분리 |

---

### ③ TokenClassifier.classify(tokens, domain=PRODUCT)

내부 3단계 파이프라인:

#### 3-A. _classify_tokens() — 토큰 → keyword_type 매핑

`search_keywords` 테이블에서 토큰을 매칭합니다.

**매칭 전략 (3단계, 우선순위 기반):**

```
Step 1: 원본 쿼리 직접 매칭
  keyword_repo.find_by_query(query)
  → "린넨 셔츠" 전체를 하나의 키워드로 사전 조회

Step 2: 연속 토큰 조합 매칭
  keyword_repo.find_by_phrase_combinations(tokens)
  → ["린넨", "셔츠"] → "린넨 셔츠" 조합으로 사전 조회

Step 3: 개별 토큰 매칭
  keyword_repo.find_by_tokens(tokens)
  → Step 1·2에서 점유된 인덱스는 제외
```

**우선순위 정렬 기준:**

```python
sorted(candidates, key=lambda x: (
    x.priority,          # 1. priority 낮을수록 우선 (0 = 최우선)
    -len(token_indices), # 2. 더 많은 토큰 커버 (복합어 우선)
    TYPE_PRIORITY[type], # 3. CATEGORY(0) > BRAND(1) > COLOR(2)
))
```

**출력:**
- `keywords` — 매칭된 키워드 + keyword_type
- `unmatched` — 매칭 실패 토큰 → OpenSearch `should` 쿼리에 사용

---

#### 3-B. _expand_keywords() — 동의어/유사어 확장

`search_keyword_relations` 에서 관계 키워드를 가져와 keywords에 추가합니다.

| relation_type | 역할 | Tier 1 포함 | Tier 2 포함 |
|--------------|------|------------|------------|
| `SAME` | 동의어 ("바지" → "팬츠") | ✅ | ✅ |
| `SIMILAR` | 유사어 ("청바지" → "데님팬츠") | ❌ | ✅ |

---

#### 3-C. _classify_for_product() — 발골사전 연결

keywords에서 BRAND/COLOR/CATEGORY 타입을 발골사전 테이블과 연결합니다.

```
keywords (expand 완료)
    │
    ├─ BRAND    → search_brand_keywords    → brand_id    → ExtractedBrandDTO
    ├─ COLOR    → search_color_keywords    → color_ids   → ExtractedColorDTO (max 3개)
    └─ CATEGORY → search_category_keywords → filter_scope → ExtractedCategoryDTO
```

**CATEGORY > BRAND 충돌 해소 (카테고리 우선 원칙):**

동일 형태소가 BRAND + CATEGORY 양쪽에 매핑되면 **브랜드를 제거하고 카테고리만 유지**.

```python
# 예: "로퍼" → BRAND("로퍼") + CATEGORY("로퍼슈즈") 동시 발골
# → 브랜드 "로퍼" 제거, 카테고리 "로퍼슈즈" 유지
extracted_brands = _remove_brands_conflicting_with_category(keywords, extracted_brands)
```

---

### ④ ZERO_UNRECOGNIZED 검사

```python
if normalized_query and (
    not analyzed.extracted_brands
    and not analyzed.extracted_colors
    and not analyzed.extracted_category
    and not analyzed.keywords
    and not analyzed.unmatched
):
    return SearchProductsResult(product_ids=[], total_count=0, fallback_tier=0)
```

발골 결과물이 **전부 없을 때만** 즉시 빈 결과 반환. OpenSearch 호출 없음.

---

### ⑤ _search_with_fallback() — Tier 1 → Tier 2

```
Tier 1: 원본 + SAME 동의어만 사용
  → total_count > 0 이면 반환 (fallback_tier=1)

Tier 2: Tier 1이 0건일 때만 실행
  → 원본 + SAME + SIMILAR 모두 사용
  → 0건이어도 반환 (fallback_tier=2, ZERO_NO_MATCH 가능)
```

| 시나리오 | fallback_tier |
|---------|:------------:|
| Tier 1 > 0건 | 1 |
| Tier 1 = 0건, Tier 2 > 0건 | 2 |
| 둘 다 0건 | 2 |

---

## 3. OpenSearch 쿼리 구조 (_build_query)

### 쿼리 조립 순서

```
must = [{"term": {"display": True}}]  ← 항상 기본

[발골사전 결과 — 우선 적용, ID 기반 정밀 필터]
  extracted_brands   → must: {"terms": {"brand.id": [ids]}}
  extracted_colors   → must: {"terms": {"color.id": [ids]}}
  extracted_category → must: 카테고리 필터 (is_service_midtype 기반)

[발골사전 없는 타입 — 텍스트 기반 필터]
  BRAND 키워드    → must: brand.label / label_kor term (OR)
  COLOR 키워드    → must: color_group.value / patterns.value / name (OR)
  CATEGORY 키워드 → must: product_midtype.value term (boost=3.0) + name (OR)

[사용자 직접 필터]
  must:     brand_ids, color_group_ids, midtype_ids, price_range
  must_not: exclude_pd_ids

[나머지 키워드 — unmatched → 관련성 검색]
  should:
    multi_match(name^3, product_no^2)
    brand.label / label_kor match (boost=2.0)
    product_midtype.value / product_subtype.value match (boost=5.0)
  minimum_should_match: 1
  min_score: 0.3 (should가 있을 때만)
```

### 발골 성공/실패별 쿼리 비교

| 상황 | 필터 타입 | 정밀도 |
|------|---------|:------:|
| `extracted_brands` 있음 | `must: brand.id terms` | 높음 |
| BRAND 키워드만 (발골 없음) | `must: brand.label term` | 중간 |
| `extracted_category` 있음 | `must: product_midtype.id terms` | 높음 |
| CATEGORY 키워드만 (발골 없음) | `must: product_midtype.value term` | 중간 |
| 발골 전부 없음 | `should: 텍스트 검색` | 낮음 |

### 카테고리 필터 상세 (is_service_midtype 기준)

```
is_service_midtype = True:
  → {"terms": {"product_midtype.id": [midtype_ids]}}
  + {"terms": {"product_subtype.id": [subtype_ids]}}  (있으면)

is_service_midtype = False:
  → {"match": {"product_type": scope_product_type}}
  + {"terms": {"product_midtype.id": [scope_midtype_ids]}}
  + (requires_name_search=True) → {"match_phrase": {"name": keyword, "slop": 1}}
```

---

## 4. 검색 파이프라인 시나리오 (pipeline_scenario)

| 시나리오 | 조건 | OpenSearch 쿼리 특성 |
|---------|------|-------------------|
| **A.정밀_필터_브랜드** | extracted_brands 있음 | must: brand.id terms |
| **A.정밀_필터_카테고리** | extracted_category 있음 | must: product_midtype.id terms |
| **A.정밀_필터_복합** | extracted 여러 개 | must 필터 복수 조합 |
| **A2.정밀_필터_Tier2** | extracted 있음 + fallback_tier=2 | SIMILAR까지 확장 |
| **B.색상_필터** | extracted_colors만 있음 | must: color.id terms |
| **C.텍스트_검색** | extracted 없음 | should: 관련성 검색, min_score=0.3 |
| **D1.ZERO_미등록** | result=0 + ZERO_UNRECOGNIZED | 사전 미등록 키워드 |
| **D2.ZERO_매칭없음** | result=0 + ZERO_NO_MATCH | 사전 있지만 상품 없음 |
| **E.판별불가** | ETC_TYPE | keyword_type=ETC, must 필터 없음 |

---

## 5. 정렬 기준 (_build_sort_query)

| SortFilter | OpenSearch sort |
|-----------|----------------|
| `RECOMMEND` (기본) | `scores.ranking` DESC → `_score` DESC |
| `HOME_RECOMMEND` | `scores.home_recommend` DESC → `_score` DESC |
| `NEW` | `created_at` DESC |
| `SALE` | `stats.order_count` DESC |
| `REVIEW` | `stats.review_count` DESC |
| `MIN_PRICE` | `price_discount` ASC |
| `MAX_PRICE` | `price_discount` DESC |
| `DISCOUNT_RATE` | `discount_rate` DESC |

---

## 6. diagnosis_codes → DB 조치 매핑

| diagnosis_code | 파이프라인 발생 위치 | 조치 테이블 | 방법 |
|---------------|-----------------|-----------|------|
| `ZERO_UNRECOGNIZED` | 초기 검사 | `search_keywords` | INSERT |
| `ZERO_NO_MATCH` | Tier 1 & 2 모두 0건 | `search_keyword_relations` | SIMILAR INSERT |
| `ETC_TYPE` | `_classify_tokens` keyword_type=ETC | `search_keywords` | type UPDATE + 매핑 INSERT |
| `NO_SYNONYM` | `_expand_keywords` SAME 없음 | `search_keyword_relations` | SAME INSERT |
| `POSSIBLE_FALLBACK` | `_classify_for_product` extracted 없음 | `search_brand/category_keywords` | INSERT |
| `BRAND_MAPPING_WRONG` | `_build_query` 잘못된 brand.id | `search_brand_keywords` | brand_id UPDATE |
| `CATEGORY_MAPPING_WRONG` | `_build_query` 카테고리 불일치 | `search_category_keywords` | midtype_ids UPDATE |

**코드 수정이 필요한 이슈 (DB만으로 불가):**

| 이슈 | 현황 |
|------|------|
| 품절 상품 필터 없음 | `must_not: is_sold_out` 없음 → 품절 상품 노출 가능 |
| `decompound_mode=none` | 복합어 미분해 → 사전에 복합어 전체 등록 필요 |
| 쿼리 토크나이징 주석 처리 | 형태소 분리 미사용 |

---

## 7. API 엔드포인트

```
GET /api/v1/search/product-results?query={keyword}&page=1&limit=50

Response:
{
  "result_query": {
    "extracted_brands": [...],    # 발골된 브랜드 (anchor_id)
    "extracted_colors": [...],    # 발골된 색상 (color_ids)
    "extracted_category": {...},  # 발골된 카테고리 (midtype_ids)
    "keywords": {...},            # 분류된 키워드 맵
    "unmatched": [...]            # 미매칭 토큰
  },
  "total_count": 1234,
  "fallback_tier": 1              # 1: Tier1, 2: SIMILAR 확장됨
}
```
