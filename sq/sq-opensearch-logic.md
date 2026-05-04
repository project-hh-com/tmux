# 상품 검색 로직 — OpenSearch 파이프라인 완전 분석

> 작성일: 2026-05-04  
> 분석 대상:
> - `danble-api/search/services/search_products_service.py`
> - `danble-api/search/domains/token_classifier.py`

---

## 1. 전체 파이프라인 흐름

```
클라이언트 요청
  GET /api/v1/search/product-results?query={kw}&page=1&limit=50
          │
          ▼
SearchProductsService.search_products(query)
          │
          ├─ [1] QueryAnalyzer.normalize(query)
          │        → 소문자 변환, 공백 정리
          │
          ├─ [2] _tokenize_with_opensearch(normalized_query)
          │        → OpenSearch Analyze API 호출
          │        → index="products", nori tokenizer
          │        → decompound_mode=none (복합어 미분해)
          │        → 실패 시 공백 기반 split() 폴백
          │
          ├─ [3] TokenClassifier.classify(tokens, domain=PRODUCT)
          │        ├─ _classify_tokens()
          │        ├─ _expand_keywords()
          │        └─ _classify_for_product()
          │
          ├─ [4] ZERO_UNRECOGNIZED 검사
          │        → 발골 결과 전부 없으면 즉시 빈 결과 반환
          │
          └─ [5] _search_with_fallback()
                   ├─ Tier 1: 원본 + SAME 동의어
                   └─ Tier 2 (Tier 1 = 0건): 원본 + SAME + SIMILAR
```

---

## 2. 단계별 상세 분석

### 2-1. 형태소 분석 (OpenSearch Tokenize)

```python
result = opensearch_plugin.tokenize(index="products", text=query)
tokens = [token["token"] for token in result["tokens"]]
```

| 특이사항 | 내용 |
|---------|------|
| tokenizer | nori (한국어 형태소 분석기) |
| `decompound_mode` | `none` → **복합어를 분해하지 않음** |
| 쿼리 토크나이징 코드 | **주석 처리 상태** → 형태소 단위 분리 미사용 |
| OpenSearch 실패 시 | `query.split()` 공백 기반 분리로 폴백 |

**`decompound_mode=none` 의 영향:**
- "린넨셔츠" → "린넨셔츠" (단일 토큰, 분해 없음)
- "맨투맨후드티" → "맨투맨후드티" (단일 토큰)
- 결과: 사전에 복합어 전체가 등록되어 있어야 매칭됨

---

### 2-2. 토큰 분류 (`_classify_tokens`)

search_keywords 테이블에서 토큰을 매칭하여 keyword_type을 부여합니다.

#### 매칭 전략 (3단계, 우선순위 기반)

```
Step 1: 원본 쿼리 직접 매칭
  → keyword_repo.find_by_query(query)
  → 공백 포함 구문 전체를 사전에서 찾음

Step 2: 연속 토큰 조합 매칭
  → keyword_repo.find_by_phrase_combinations(tokens)
  → ["린넨", "셔츠"] → "린넨 셔츠" 로 조합 후 사전 조회

Step 3: 개별 토큰 매칭
  → keyword_repo.find_by_tokens(tokens)
  → Step 1, 2에서 점유된 인덱스는 제외
```

#### 우선순위 정렬 기준

```python
sorted(
    candidates,
    key=lambda x: (
        x[1][0].priority,      # 1. priority 낮을수록 우선
        -len(x[1][1]),          # 2. 토큰 수 많을수록 우선 (복합어 우선)
        TYPE_PRIORITY[type],    # 3. CATEGORY(0) > BRAND(1) > COLOR(2)
    )
)
```

#### 결과

| 분류 | 설명 |
|------|------|
| `keywords` | search_keywords에서 매칭된 키워드 (keyword_type: BRAND/COLOR/CATEGORY/ETC/STYLE) |
| `unmatched` | 매칭되지 않은 토큰 → OpenSearch should 쿼리에 사용 |

---

### 2-3. 키워드 확장 (`_expand_keywords`)

search_keyword_relations 테이블에서 동의어·유사어를 가져와 keywords에 추가합니다.

```python
relations = keyword_repo.find_relations(list(keywords.keys()))
# relation_type: SAME (동의어) 또는 SIMILAR (유사어)
```

| relation_type | 역할 | 사용 시점 |
|-------------|------|---------|
| `SAME` | 동의어 (Tier 1에 포함) | Tier 1 검색 기본 포함 |
| `SIMILAR` | 유사어 (Tier 2에만 포함) | Tier 1이 0건일 때만 활성화 |

확장된 키워드는 `expanded_keywords`에 포함되며, `relation` 필드로 원본/동의어/유사어를 구분합니다.

---

### 2-4. 발골 전략 (`_classify_for_product`)

keywords에서 BRAND / COLOR / CATEGORY 타입을 발골사전과 연결합니다.

#### 발골 흐름

```
keywords (expand 완료) 입력
    │
    ├─ BRAND 타입 키워드 → search_brand_keywords 조회 → brand_id 획득 → ExtractedBrandDTO
    ├─ COLOR 타입 키워드 → search_color_keywords 조회 → color_ids 획득 → ExtractedColorDTO (max 3개)
    └─ CATEGORY 타입 키워드 → search_category_keywords 조회 → filter scope 획득 → ExtractedCategoryDTO
```

#### CATEGORY > BRAND 충돌 해소

동일 형태소가 BRAND와 CATEGORY 양쪽에 매핑되면 **카테고리 우선, 브랜드 제거**:

```python
# 예: "로퍼" → BRAND("로퍼") + CATEGORY("로퍼슈즈") 동시 발골 시
extracted_brands = _remove_brands_conflicting_with_category(keywords, extracted_brands_initial)
```

normalized_keyword가 겹치면 BRAND를 제거하고 CATEGORY만 유지합니다.

#### 발골 완료 후 keywords 정리

발골사전에서 추출한 타입은 `keywords`에서도 제거 (중복 방지):

```python
if extracted_brands:
    final_keywords = {k: v for k, v in final_keywords.items() if v.keyword_type != "BRAND"}
if extracted_colors:
    final_keywords = {k: v for k, v in final_keywords.items() if v.keyword_type != "COLOR"}
if extracted_category:
    final_keywords = {k: v for k, v in final_keywords.items() if v.keyword_type != "CATEGORY"}
# STYLE 타입도 항상 제거
final_keywords = {k: v for k, v in final_keywords.items() if v.keyword_type != "STYLE"}
```

---

### 2-5. ZERO_UNRECOGNIZED 검사

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

발골 결과물이 **전부 없으면** OpenSearch를 호출하지 않고 즉시 빈 결과를 반환합니다.  
→ `diagnosis_code: ZERO_UNRECOGNIZED` 발생 지점

---

### 2-6. Fallback 전략 (`_search_with_fallback`)

```
Tier 1: use_expanded=False
  → analyzed.get_original_and_synonyms()  ← SAME 관계 포함, SIMILAR 제외
  → total_count > 0 이면 Tier 1 결과 반환

Tier 2 (Tier 1이 0건일 때만):
  → use_expanded=True  ← SAME + SIMILAR 모두 포함
  → 결과가 0건이어도 Tier 2 결과를 반환 (ZERO_NO_MATCH 가능)
```

| 시나리오 | 결과 |
|---------|------|
| Tier 1 > 0건 | Tier 1 결과 반환 (fallback_tier=1) |
| Tier 1 = 0건, Tier 2 > 0건 | Tier 2 결과 반환 (fallback_tier=2) |
| Tier 1 = 0건, Tier 2 = 0건 | 빈 결과 (ZERO_NO_MATCH) |
| SIMILAR 관계 없음 | Tier 2 = Tier 1과 동일 결과 |

---

## 3. OpenSearch 쿼리 구조 (`_build_query`)

### 3-1. 쿼리 조립 흐름

```
must_filters = [{"term": {"display": True}}]  ← 항상 기본 포함

발골사전 결과 처리 (우선 적용):
  ├─ extracted_brands → must: {"terms": {"brand.id": [brand_ids]}}
  ├─ extracted_colors → must: {"terms": {"color.id": [color_ids]}}
  └─ extracted_category → must: 카테고리 필터 (아래 상세)

발골사전 없는 타입의 entity 필터 (fallback):
  ├─ BRAND 키워드 → must: brand.label/label_kor term (OR)
  ├─ COLOR 키워드 → must: color_group.value / patterns.value / name match (OR)
  └─ CATEGORY 키워드 → must: product_midtype.value term (boost=3.0) + name match (OR)

사용자 필터:
  ├─ must: brand_ids, color_group_ids, midtype_ids, price_range, brand_type_ids
  └─ must_not: exclude_pd_ids

나머지 키워드 (unmatched):
  └─ should: multi_match(name^3, product_no^2) + brand.label/label_kor + product_midtype.value(boost=5.0)
```

### 3-2. 발골사전 있을 때 vs 없을 때

| 상황 | 쿼리 타입 | 효과 |
|------|---------|------|
| `extracted_brands` 있음 | `must: {"terms": {"brand.id": [id1, id2]}}` | 정확한 brand.id 필터 (精密) |
| `extracted_brands` 없음, BRAND 키워드 있음 | `must: brand.label term or label_kor term` | 텍스트 기반 필터 (오타 취약) |
| `extracted_category` 있음 | `must: product_midtype.id terms 또는 product_type match` | 구조화된 카테고리 필터 |
| `extracted_category` 없음, CATEGORY 키워드 있음 | `must: product_midtype.value term (boost=3.0)` | 중분류명 텍스트 필터 |
| 발골 전부 없음 (ETC_TYPE 등) | `should: unmatched 텍스트 검색` | 전체 인덱스 대상 관련성 검색 |

### 3-3. 카테고리 필터 상세 로직

```
is_service_midtype = True:
  → {"terms": {"product_midtype.id": [midtype_ids]}}  ← 서비스 중분류 직접 필터
  + (product_subtype_ids 있으면) {"terms": {"product_subtype.id": [subtype_ids]}}

is_service_midtype = False:
  → {"match": {"product_type": {"query": search_scope_product_type, "operator": "and"}}}
  + {"terms": {"product_midtype.id": [search_scope_product_midtype_ids]}}
  + (requires_name_search=True) {"match_phrase": {"name": {"query": keyword, "slop": 1}}}
```

### 3-4. min_score 적용 조건

```python
# should 쿼리(unmatched)가 있을 때만 min_score=0.3 적용
has_should = bool(query_bool.get("should"))
if has_should:
    payload["min_score"] = 0.3
```

| 상황 | min_score |
|------|----------|
| must 필터만 있음 (발골 성공, unmatched=없음) | 미적용 |
| should 쿼리 있음 (unmatched 존재) | 0.3 적용 |
| minimum_should_match=1 | should 쿼리 중 최소 1개 매칭 필요 |

---

## 4. 발골 성공/실패별 결과 차이

### 시나리오 A: 발골 완전 성공 (BRAND + CATEGORY)

```
쿼리: "자라 청바지"
  │
  ├─ 토크나이징: ["자라", "청바지"]
  ├─ 분류: "자라" → BRAND, "청바지" → CATEGORY
  ├─ 발골: extracted_brands=[{brand_id: 42}], extracted_category={product_midtype_ids: [5]}
  │
  └─ 쿼리: {
       bool: {
         must: [
           {"term": {"display": True}},
           {"terms": {"brand.id": [42]}},      ← 브랜드 정확 필터
           {"terms": {"product_midtype.id": [5]}} ← 카테고리 정확 필터
         ]
       }
     }

결과: brand.id=42 AND product_midtype.id=5 인 상품만 반환 (정밀)
POSSIBLE_FALLBACK 없음, should 없음, min_score 미적용
```

### 시나리오 B: 카테고리만 발골 성공

```
쿼리: "검정 청바지"
  │
  ├─ 분류: "검정" → COLOR (SAME: "블랙"), "청바지" → CATEGORY
  ├─ 발골: extracted_colors=[{color_ids: [1, 2]}], extracted_category={product_midtype_ids: [5]}
  │
  └─ 쿼리: {
       bool: {
         must: [
           {"term": {"display": True}},
           {"terms": {"color.id": [1, 2]}},
           {"terms": {"product_midtype.id": [5]}}
         ]
       }
     }
```

### 시나리오 C: POSSIBLE_FALLBACK (발골 실패 — should만)

```
쿼리: "에코백"
  │
  ├─ 분류: "에코백" → ETC (keyword_type이 CATEGORY/BRAND가 아님)
  ├─ 발골: extracted_brands=[], extracted_colors=[], extracted_category=None
  ├─ final_keywords에 "에코백" 남음 (ETC 타입)
  ├─ _build_query: 발골사전 필터 없음, ETC 타입은 entity 필터에도 포함 안 됨
  ├─ unmatched에 "에코백" 포함 → should 쿼리 생성
  │
  └─ 쿼리: {
       bool: {
         must: [{"term": {"display": True}}],
         should: [
           {"multi_match": {"query": "에코백", "fields": ["name^3", "product_no^2"]}},
           {"bool": {"should": [brand.label match, brand.label_kor match]}},
           {"bool": {"should": [product_midtype.value match(boost=5), product_subtype.value match(boost=5)]}}
         ],
         minimum_should_match: 1
       },
       min_score: 0.3
     }

결과: 전체 상품 대상 텍스트 검색 → total_count 매우 큼 (POSSIBLE_FALLBACK)
진단: POSSIBLE_FALLBACK, ETC_TYPE
```

### 시나리오 D: ZERO_RESULT — ZERO_UNRECOGNIZED

```
쿼리: "알파카케이시"  (사전에 없는 키워드)
  │
  ├─ 토크나이징: ["알파카케이시"]
  ├─ 분류: 매칭 없음 → keywords={}, unmatched=["알파카케이시"]
  ├─ 발골: 전부 없음
  ├─ 검사: keywords도 없고 unmatched만 있는 경우는 통과 (unmatched → should 처리)
  │
  주의: "전부 없음" 조건은 keywords AND unmatched AND extracted 모두 없을 때
  → 실제로 unmatched가 있으면 should 쿼리로 검색 시도함
  → 검색 결과가 0건이면 ZERO_NO_MATCH (Tier 1, Tier 2 모두 0건)
  → 사전에 아예 없는 키워드 + 상품명에도 없으면 0건
```

**실제 ZERO_UNRECOGNIZED 발생 조건:**  
`normalized_query`가 있는데 `extracted_*` AND `keywords` AND `unmatched` 모두 빈 상태  
(현실적으로 unmatched에라도 포함되므로 순수 ZERO_UNRECOGNIZED는 드뭄)

---

## 5. 관련 DB 테이블과 파이프라인 연결

| 테이블 | 파이프라인 역할 | 컬럼 |
|--------|--------------|------|
| `search_keywords` | `_classify_tokens()` — 토큰 → keyword_type 매핑 | `keyword`, `normalized_keyword`, `keyword_type`(BRAND/COLOR/CATEGORY/ETC/STYLE), `rank`, `result_product_count`, `priority` |
| `search_keyword_relations` | `_expand_keywords()` — 동의어/유사어 확장 | `source_keyword_id`, `target_keyword_id`, `relation_type`(SAME/SIMILAR), `relation_score` |
| `search_brand_keywords` | `_extract_brands_from_keywords()` — brand_id 발골 | `search_keyword_id`, `brand_id` |
| `search_color_keywords` | `_extract_colors_from_keywords()` — color_ids 발골 | `search_keyword_id`, `variant_ids` |
| `search_category_keywords` | `_extract_category_from_keywords()` — 카테고리 필터 발골 | `search_keyword_id`, `product_type`, `product_midtype_ids`, `product_subtype_ids`, `search_scope_product_type`, `search_scope_product_midtype_ids`, `requires_name_search`, `is_service_midtype` |

---

## 6. 각 테이블 수정의 예상 효과

| 수정 | 대상 테이블 | 효과 | diagnosis_code 해소 |
|------|-----------|------|-------------------|
| 미등록 키워드 INSERT | `search_keywords` | 토큰이 사전에 매칭 → unmatched → should 로 이동 또는 타입 필터 활성화 | `ZERO_UNRECOGNIZED` |
| keyword_type `ETC` → `CATEGORY` UPDATE | `search_keywords` | ETC→CATEGORY 변경 → `_classify_for_product`에서 카테고리 발골 시도 | `ETC_TYPE` |
| keyword_type `ETC` → `BRAND` UPDATE + brand 매핑 INSERT | `search_keywords` + `search_brand_keywords` | ETC→BRAND 변경 → brand.id 필터 활성화 | `ETC_TYPE` |
| SAME 관계 INSERT | `search_keyword_relations` | Tier 1 검색 범위 확장 → 관련 상품 추가 노출 | `NO_SYNONYM` |
| SIMILAR 관계 INSERT | `search_keyword_relations` | Tier 2 폴백 활성화 → Tier 1=0건 시 관련 결과 반환 | `ZERO_NO_MATCH` |
| brand 매핑 INSERT | `search_brand_keywords` | brand_id 직접 필터 → POSSIBLE_FALLBACK 해소 | `POSSIBLE_FALLBACK` |
| category 매핑 INSERT | `search_category_keywords` | product_midtype.id 직접 필터 → POSSIBLE_FALLBACK 해소 | `POSSIBLE_FALLBACK` |
| brand_id 수정 | `search_brand_keywords` | 잘못된 brand.id 필터 → 올바른 브랜드 상품 반환 | `BRAND_MAPPING_WRONG` |
| category 매핑 수정 | `search_category_keywords` | product_type / midtype 불일치 수정 | `CATEGORY_MAPPING_WRONG` |

---

## 7. 코드 수정이 필요한 이슈 (DB 수정으로 불가)

| 이슈 | 현재 상태 | 수정 방법 |
|------|---------|---------|
| `is_sold_out` 필터 없음 | OpenSearch 쿼리에 `must_not: {"term": {"is_sold_out": true}}` 없음 → 품절 상품 상위 노출 가능 | `_build_query`에 `must_not` 조건 추가 |
| `decompound_mode=none` | 복합어 미분해 → "린넨셔츠" 전체가 단일 토큰 → 사전에 복합어 전체 등록 필요 | OpenSearch 인덱스 설정 변경 또는 사전 확장 |
| 쿼리 토크나이징 주석 처리 | 형태소 단위 분리 미사용 → 복합어 검색 정확도 저하 | `LOW_RELEVANCE` 해소를 위해 토크나이징 코드 주석 해제 검토 |

---

## 8. 정렬 기준 (`_build_sort_query`)

| SortFilter | 정렬 방식 |
|-----------|---------|
| `RECOMMEND` | `scores.ranking` DESC → `_score` DESC (기본값) |
| `HOME_RECOMMEND` | `scores.home_recommend` DESC → `_score` DESC |
| `NEW` | `created_at` DESC |
| `SALE` | `stats.order_count` DESC |
| `REVIEW` | `stats.review_count` DESC |
| `MIN_PRICE` | `price_discount` ASC |
| `MAX_PRICE` | `price_discount` DESC |
| `DISCOUNT_RATE` | `discount_rate` DESC |
| `RANKING` | `scores.ranking` DESC → `_score` DESC |

---

## 9. 검색 결과 타입 (`SearchProductsResult`)

```python
@dataclass
class SearchProductsResult:
    analyzed: AnalyzedQueryDTO    # 분석된 쿼리 정보 (발골 결과 포함)
    product_ids: List[int]        # 검색된 상품 ID 목록 (page/limit 기준)
    total_count: int              # 전체 결과 수 (POSSIBLE_FALLBACK 판단 기준: > 2000)
    opensearch_query: dict        # 실제 실행된 쿼리 (디버깅용)
    fallback_tier: int            # 0: ZERO_UNRECOGNIZED, 1: Tier1, 2: Tier2
```

---

## 10. sq-v2 diagnosis_codes와 파이프라인 매핑 요약

| diagnosis_code | 파이프라인 발생 위치 | 원인 | 수정 가능 여부 |
|---------------|-----------------|------|-------------|
| `ZERO_UNRECOGNIZED` | `search_products` 초기 검사 | 발골 결과 전부 없음 | ✅ `search_keywords` INSERT |
| `ZERO_NO_MATCH` | `_search_with_fallback` Tier 1 & 2 모두 0건 | 상품 없음 | ✅ `search_keyword_relations` SIMILAR INSERT |
| `ETC_TYPE` | `_classify_tokens` → keyword_type=ETC | 분류 안 됨 → must 필터 없음 | ✅ keyword_type UPDATE + 매핑 INSERT |
| `NO_SYNONYM` | `_expand_keywords` → SAME 관계 없음 | Tier 1 확장 없음 | ✅ `search_keyword_relations` SAME INSERT |
| `POSSIBLE_FALLBACK` | `_classify_for_product` → extracted 없음 | 발골사전 미등록 | ✅ `search_brand/category_keywords` INSERT |
| `BRAND_MAPPING_WRONG` | `_build_query` → 잘못된 brand.id 필터 | brand_id 잘못 매핑 | ✅ `search_brand_keywords` UPDATE |
| `CATEGORY_MAPPING_WRONG` | `_build_query` → 카테고리 필터 불일치 | product_type/midtype 불일치 | ✅ `search_category_keywords` UPDATE |
| `LOW_RELEVANCE` | OpenSearch 관련성 스코어 낮음 | 분석기/쿼리 설계 문제 | ❌ 코드 수정 필요 |
| `SOLDOUT_EXPOSED` | `_build_query` → must_not 없음 | is_sold_out 필터 미설정 | ❌ 코드 수정 필요 |
