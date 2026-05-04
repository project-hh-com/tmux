# Danble 검색 DB 스키마

> 작성일: 2026-05-04  
> 대상: `danble-api/search/models/` 전체  
> 연관: `search-pipeline.md`

---

## 테이블 관계도

```
search_keywords (검색어 사전)
    │
    ├─ 1:1 → search_brand_keywords     (브랜드 발골사전)
    ├─ 1:1 → search_category_keywords  (카테고리 발골사전)
    ├─ 1:1 → search_color_keywords     (색상 발골사전)
    ├─ 1:1 → search_keyword_rankings   (검색 결과 통계)
    │
    ├─ 1:N → search_keyword_relations  (source_keyword_id)
    └─ 1:N → search_keyword_relations  (target_keyword_id)

matchup_keywords (매치업 키워드)
    │
    ├─ 1:N → matchup_keyword_relations (source_keyword_id)
    └─ 1:N → matchup_keyword_relations (target_keyword_id)
```

---

## 1. search_keywords — 검색어 사전

검색 파이프라인의 핵심 사전. 모든 발골 및 분류의 기준.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK (자동 증가) |
| `keyword` | varchar | ✗ | 원본 키워드 (UNIQUE) |
| `keyword_type` | varchar(32) | ✗ | 키워드 종류 → [KeywordType](#keywordtype) |
| `converted_keyword` | varchar(100) | ✓ | 변환 키워드 (정규화 후 실제 검색에 쓰이는 형태) |
| `normalized_keyword` | varchar(100) | ✓ | 정규화된 키워드 (소문자·특수문자 제거) |
| `category_main` | varchar(32) | ✗ | 키워드 대분류 → [CategoryMain](#categorymain) |
| `priority` | int | ✗ | 우선순위 (낮을수록 먼저 매칭, default=100) |
| `is_deleted` | bool | ✗ | 삭제여부 (default=false) |
| `is_recommended` | bool | ✗ | 추천 키워드 노출 여부 (default=false) |
| `allow_rising` | bool | ✗ | 급상승 검색어 허용 여부 (default=true) |
| `created_at` | datetime | ✗ | 생성일자 |
| `updated_at` | datetime | ✗ | 수정일자 |

> **DEPRECATED 컬럼** (→ `search_keyword_rankings`로 이관됨)  
> `result_product_count`, `result_style_count`, `recent_order_count`,  
> `md_score`, `auto_score`, `rank`, `before_rank`, `rank_updated_at`

### KeywordType

| 값 | 의미 | 발골사전 연결 |
|----|------|:------:|
| `BRAND` | 브랜드명 | `search_brand_keywords` |
| `CATEGORY` | 카테고리명 | `search_category_keywords` |
| `COLOR` | 색상명 | `search_color_keywords` |
| `ETC` | 분류 불가 (진단코드: ETC_TYPE) | — |

### CategoryMain

| 값 | 설명 |
|----|------|
| `ENTRY` | 진입 키워드 (메인 카테고리) |
| `NON_ENTRY` | 비진입 키워드 |
| `TOP` | 상의 |
| `BOTTOM` | 하의 |
| `OUTER` | 아우터 |
| `BAG` | 가방 |
| `SHOES` | 신발 |
| `COLOR` | 색상 계열 |
| `PATTERN` | 패턴 계열 |
| `MATERIAL` | 소재 계열 |
| `ETC` | 기타 |
| `UNKNOWN` | 미분류 |

---

## 2. search_keyword_relations — 검색어 관계망

키워드 간 동의어·유사어 관계. Tier1/Tier2 폴백 확장의 핵심.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK |
| `source_keyword_id` | int FK | ✗ | 기준 키워드 (→ search_keywords) |
| `target_keyword_id` | int FK | ✗ | 관계 키워드 (→ search_keywords) |
| `relation_type` | varchar(32) | ✗ | 관계 유형 → [KeywordRelationType](#keywordrelationtype) |
| `relation_score` | float | ✗ | 유사도 점수 (0.0 ~ 1.0) |
| `created_at` | datetime | ✗ | 생성일자 |
| `updated_at` | datetime | ✗ | 수정일자 |

UNIQUE 제약: `(source_keyword_id, target_keyword_id)`

### KeywordRelationType

| 값 | 의미 | Tier 1 | Tier 2 | 예시 |
|----|------|:------:|:------:|------|
| `SAME` | 동의어 | ✅ | ✅ | "바지" → "팬츠" |
| `SIMILAR` | 유사어 | ❌ | ✅ | "청바지" → "데님팬츠" |

> 진단코드 `NO_SYNONYM`: source 키워드에 SAME 관계가 없을 때 발생

---

## 3. search_brand_keywords — 브랜드 발골사전

keyword_type=BRAND인 키워드를 실제 brand_id로 연결.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK |
| `search_keyword_id` | int FK | ✗ | → search_keywords (OneToOne, UNIQUE) |
| `brand_id` | int | ✓ | 연결된 브랜드 ID (null이면 미연결 = POSSIBLE_FALLBACK) |
| `updated_at` | datetime | ✗ | 수정일자 |

> `brand_id IS NULL` → OpenSearch brand.label 텍스트 검색으로 폴백  
> 진단코드 `POSSIBLE_FALLBACK`: brand_id가 없어 정밀 필터 불가  
> 진단코드 `BRAND_MAPPING_WRONG`: brand_id가 잘못된 브랜드를 가리킬 때

---

## 4. search_category_keywords — 카테고리 발골사전

keyword_type=CATEGORY인 키워드를 상품 분류 체계로 연결.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK |
| `search_keyword_id` | int FK | ✗ | → search_keywords (OneToOne, UNIQUE) |
| `product_type` | varchar(32) | ✗ | 상품 대분류 (TOP/BOTTOM/OUTER/SHOES/BAG/ETC) |
| `product_midtype_ids` | int[] | ✗ | 중분류 variant ID 목록 (default=[]) |
| `product_subtype_ids` | int[] | ✗ | 소분류 variant ID 목록 (default=[]) |
| `search_scope_product_type` | varchar(32) | ✓ | 서칭 단위 대분류 |
| `search_scope_product_midtype_ids` | int[] | ✓ | 서칭 단위 중분류 variant IDs |
| `requires_name_search` | bool | ✗ | 상품명 검색 필요 여부 (default=false) |
| `name_search_tokens` | varchar(100)[] | ✓ | 상품명 검색어 토큰 목록 |
| `updated_at` | datetime | ✗ | 수정일자 |

### is_service_midtype 판별 로직

```python
# get_filter_scope() 내부
if self.product_midtype_ids or self.product_subtype_ids:
    is_service_midtype = True   # 서비스 중분류 존재 → 중분류 ID 필터
else:
    is_service_midtype = False  # 미존재 → 대분류 필터 + 상품명 검색
```

| 예시 키워드 | is_service_midtype | OpenSearch 쿼리 방식 |
|------------|:-----------------:|---------------------|
| "슬랙스" | True | `product_midtype.id terms` |
| "롱코트" | False | `product_type match` + `name match_phrase` |
| "조거팬츠" | False | `product_type match` + `name match_phrase` |

> 진단코드 `POSSIBLE_FALLBACK`: product_midtype_ids=[] 이고 requires_name_search=False  
> 진단코드 `CATEGORY_MAPPING_WRONG`: 카테고리 ID가 실제 상품 분류와 불일치

---

## 5. search_color_keywords — 색상 발골사전

keyword_type=COLOR인 키워드를 색상 variant ID로 연결.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK |
| `search_keyword_id` | int FK | ✗ | → search_keywords (OneToOne, UNIQUE) |
| `variant_ids` | int[] | ✗ | 색상 variant ID 목록 (default=[]) |
| `updated_at` | datetime | ✗ | 수정일자 |

> 파이프라인에서 최대 3개 색상까지 발골 (ExtractedColorDTO)  
> `variant_ids` → OpenSearch `color.id` terms 필터로 변환

---

## 6. search_keyword_rankings — 검색 결과 통계

search_keywords의 DEPRECATED 통계 컬럼을 분리한 테이블.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK |
| `search_keyword_id` | int FK | ✗ | → search_keywords (OneToOne) |
| `result_product_count` | int(unsigned) | ✗ | 검색 결과 상품 수 |
| `result_style_count` | int(unsigned) | ✗ | 검색 결과 스타일 수 |
| `recent_order_count` | int(unsigned) | ✗ | 최근 7일 주문 수 |
| `md_score` | float | ✗ | MD 부여 점수 |
| `auto_score` | float | ✗ | 자동 분석 점수 |
| `rank` | int | ✓ | 현재 순위 |
| `before_rank` | int | ✓ | 이전 순위 |
| `rank_updated_at` | datetime | ✓ | 순위 업데이트 일시 |

---

## 7. matchup_keywords — 매치업 키워드 사전

검색어 조합 추천(매치업 기능)에 사용하는 키워드.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK |
| `keyword` | varchar | ✗ | 매치업 키워드 (UNIQUE) |
| `is_deleted` | bool | ✗ | 삭제여부 |
| `created_at` | datetime | ✗ | 생성일자 |
| `updated_at` | datetime | ✗ | 수정일자 |

---

## 8. matchup_keyword_relations — 매치업 키워드 관계망

매치업 키워드 간 조합 추천 관계.

| 컬럼 | 타입 | NULL | 설명 |
|------|------|:----:|------|
| `id` | int | ✗ | PK |
| `source_keyword_id` | int FK | ✗ | → matchup_keywords |
| `target_keyword_id` | int FK | ✗ | → matchup_keywords |
| `description` | text | ✓ | 조합 추천 설명 |
| `created_at` | datetime | ✗ | 생성일자 |
| `updated_at` | datetime | ✗ | 수정일자 |

UNIQUE 제약: `(source_keyword_id, target_keyword_id)`

---

## 9. 조치 유형별 SQL 패턴

skq agent가 생성하는 SQL의 대상 테이블 매핑.

| 진단코드 | 대상 테이블 | SQL 패턴 |
|---------|-----------|---------|
| `ZERO_UNRECOGNIZED` | `search_keywords` | `INSERT INTO search_keywords ...` |
| `ZERO_NO_MATCH` | `search_keyword_relations` | `INSERT INTO search_keyword_relations (source, target, SIMILAR)` |
| `ETC_TYPE` | `search_keywords` | `UPDATE search_keywords SET keyword_type = '...' WHERE id = ?` |
| `NO_SYNONYM` | `search_keyword_relations` | `INSERT INTO search_keyword_relations (source, target, SAME)` |
| `POSSIBLE_FALLBACK` | `search_brand_keywords` / `search_category_keywords` | `UPDATE ... SET brand_id = ?` or `UPDATE ... SET product_midtype_ids = ?` |
| `BRAND_MAPPING_WRONG` | `search_brand_keywords` | `UPDATE search_brand_keywords SET brand_id = ? WHERE search_keyword_id = ?` |
| `CATEGORY_MAPPING_WRONG` | `search_category_keywords` | `UPDATE search_category_keywords SET product_midtype_ids = ? WHERE search_keyword_id = ?` |

---

## 10. OpenSearch `products` 인덱스 — 주요 필드

검색 쿼리가 참조하는 OpenSearch 필드 목록.

| 필드 | 타입 | 사용 위치 |
|------|------|---------|
| `display` | bool | must: `{"term": {"display": true}}` — 항상 기본 |
| `brand.id` | int | must: extracted_brands → terms 필터 |
| `brand.label` | keyword | must: BRAND 키워드 텍스트 매칭 |
| `brand.label_kor` | keyword | must: BRAND 키워드 한글 텍스트 매칭 |
| `color.id` | int | must: extracted_colors → terms 필터 |
| `color_group.value` | keyword | must: COLOR 키워드 텍스트 매칭 |
| `patterns.value` | keyword | must: COLOR 키워드 패턴 매칭 |
| `product_midtype.id` | int | must: extracted_category → terms 필터 |
| `product_midtype.value` | keyword | must: CATEGORY 키워드 텍스트 / boost=3.0 |
| `product_subtype.id` | int | must: extracted_category subtype 필터 |
| `product_subtype.value` | keyword | should: 관련성 검색 / boost=5.0 |
| `product_type` | keyword | must: is_service_midtype=False 대분류 필터 |
| `name` | text | should: multi_match / boost=3.0 |
| `product_no` | keyword | should: multi_match / boost=2.0 |
| `scores.ranking` | float | sort: RECOMMEND 기본 정렬 |
| `scores.home_recommend` | float | sort: HOME_RECOMMEND 정렬 |
| `price_discount` | int | sort: MIN_PRICE / MAX_PRICE |
| `discount_rate` | float | sort: DISCOUNT_RATE |
| `stats.order_count` | int | sort: SALE |
| `stats.review_count` | int | sort: REVIEW |
| `created_at` | datetime | sort: NEW |
