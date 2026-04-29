# Danble 검색 시스템 — 현황 분석 및 개선 포인트

> sq 에이전트가 검색 품질을 평가·개선할 때 참고하는 레퍼런스 문서입니다.
> 분석 기준: 2026-04

---

## 1. 인프라 현황

| 항목 | 값 |
|------|-----|
| 엔진 | Amazon OpenSearch 2.17 |
| 클러스터 | m7g.medium.search × 2노드, 2 AZ (고가용성) |
| 스토리지 | EBS gp3 50GB |
| 접근 방식 | VPC 내부 전용 (외부 직접 접근 불가) |
| 엔드포인트 | `search.danble.co.kr` (prod) / `alpha-search.danble.co.kr` (alpha) |
| 인증 | AWS Signature v4 (boto3 + requests-aws4auth) |
| Elasticsearch | ❌ 미사용 — OpenSearch만 운영 |

---

## 2. 인덱스 구성

| 인덱스 | 용도 |
|--------|------|
| `products` | 상품 검색 (핵심) |
| `keywords` | 자동완성 / 검색어 추천 |
| `styles` | 스타일 검색 |
| `brands` | 브랜드 검색 |
| `qc_products` | QC 작업 관리 (검색 외 용도) |

---

## 3. 현재 적용된 기능 ✅

### 3-1. 한국어 형태소 분석기

- **Nori Tokenizer** 적용 (`danble_tokenizer`)
- **커스텀 사전** 등록 (`OPENSEARCH_CUSTOM_DICTIONARY_PACKAGE_ID`) — 브랜드명, 패션 용어 등 포함 추정
- **nori_readingform** 필터 — 한자를 한글 독음으로 변환
- **NGram Tokenizer** (min 2, max 10) — 부분 문자열 매칭 지원

```json
"danble_tokenizer": {
    "type": "nori_tokenizer",
    "decompound_mode": "none",
    "user_dictionary": "analyzers/{OPENSEARCH_CUSTOM_DICTIONARY_PACKAGE_ID}"
}
```

### 3-2. 키워드 분류 체계 (발골)

검색어를 DB(`search_keywords`)에서 조회해 타입별로 검색 필드를 좁힘:

| 키워드 타입 | 검색 대상 필드 |
|------------|-------------|
| `BRAND` | `brand.label`, `brand.label_kor` |
| `CATEGORY` | `name`, `product_midtype.value`, `product_type` |
| `COLOR` | `name`, `colors.value`, `patterns.value` |
| `ETC` | 전체 필드 |

### 3-3. 유사어/동의어 확장

`SearchKeywordRelation` 테이블을 통해 관련 검색어로 쿼리 확장:

| 관계 타입 | 설명 | 예시 |
|----------|------|------|
| `SAME` (동의어) | 완전히 같은 의미 | 청바지 = 데님진 |
| `SIMILAR` (유사어) | 관련된 의미 | 후드티 ~ 맨투맨 |

### 3-4. Fallback 전략

- Tier 1: 원본 검색어 + 동의어(`SAME`)
- Tier 2: Tier 1 결과 0건 → 유사어(`SIMILAR`)까지 확장

### 3-5. 정렬 옵션

| 정렬 | 기준 |
|------|------|
| 기본 / RANKING | `scores.ranking` 내림차순 |
| 신상 (NEW) | `id` 내림차순 |
| 판매 (SALE) | `stats.order_count` 내림차순 |
| 리뷰 (REVIEW) | `stats.review_count` 내림차순 |
| 낮은가격 | `price_discount` 오름차순 |
| 높은가격 | `price_discount` 내림차순 |
| 할인율 | `discount_rate` 내림차순 |

### 3-6. 7일 롤링 통계

인덱스 내 `stats` 필드에 실시간성 메트릭 포함:
- `order_count_7d`, `ordered_user_count_7d`, `page_view_count_7d`, `conversion_rate_7d`

---

## 4. 완료된 개선 사항 ✅

| 날짜 | 항목 | 내용 |
|------|------|------|
| 2026-04 | 디버그 print 제거 | `search_service.py` `_make_product_search_query` 내 `print(should_conditions)` 제거 |

---

## 5. 개선이 필요한 부분 ⚠️

### 4-1. 오타 허용(Fuzzy Search) — 미적용

**현황**: `QueryAnalyzer`가 특수문자 제거 + 소문자 변환만 수행. Fuzzy 설정 없음.

**영향**: "나이크" → 나이키, "져킷" → 재킷 같은 오타가 결과 0건으로 처리됨.

**개선 방향**:
```python
# 쿼리 빌더에 fuzzy 추가 예시
{
    "multi_match": {
        "query": keyword,
        "fields": match_fields,
        "fuzziness": "AUTO",   # ← 추가
        "prefix_length": 1
    }
}
```

---

### 4-2. 쿼리 토크나이징 비활성화 — 주석 처리된 코드

**현황**: `search_service.py` 내 OpenSearch `_analyze` 호출 블록이 주석 처리되어 있음. 쿼리 시점에 형태소 분석을 활용하지 않고 있음.

```python
# 현재 주석 처리된 상태 (search_service.py L403~409)
# tokenized_words = opensearch_plugin.tokenize(index="products", text=input.query)
# tokenized_words = [
#     word["token"] for word in tokenized_words["tokens"] if word["type"] == "word"
# ]
```

**영향**: "가죽 재킷"을 검색할 때 형태소 단위 분리 없이 그대로 전달됨.

---

### 4-3. 품절 상품 기본 필터 없음

**현황**: `is_sold_out` 필드가 인덱스에 존재하지만 `_make_product_filter_query`에서 기본 제외 조건으로 설정되어 있지 않음. `display: true`만 필터링.

**영향**: 품절 상품이 검색 상위에 노출되어 사용자 이탈 유발 가능.

**개선 방향**:
```python
# _make_product_filter_query 기본 필터에 추가
_filters = [
    {"term": {"display": True}},
    {"term": {"is_sold_out": False}},   # ← 추가
]
```

---

### 4-4. decompound_mode 문서-코드 불일치

**현황**:
- `product_index_config.json` 코드: `"decompound_mode": "none"`
- `docs/policies/search/README.md` 문서: `"Decompound Mode: mixed"`

**영향**: 복합명사 분해 방식이 실제로 어떻게 동작하는지 불확실. "등산바지"를 "등산 + 바지"로 분해하는지 여부 미확인.

**확인 필요**: 실제 인덱스 설정을 VPC 내부에서 직접 조회해야 확인 가능.

---

### 4-5. 브랜드 분석기 정의 미확인

**현황**: 브랜드 검색 쿼리에서 `danble_brand_analyzer`를 참조하지만, 읽은 인덱스 설정 파일에서 해당 분석기 정의를 찾을 수 없음.

**확인 필요**: `brand_index_config.json` 또는 실제 인덱스 매핑에서 정의 확인 필요.

---

## 6. sq 스코어러 활용 시 주의사항

| 평가 항목 | DB/코드 근거 | 비고 |
|----------|------------|------|
| 결과 0건 여부 | `search_keyword_rankings.result_product_count` | 직접 측정 가능 |
| 이중 의도 커버리지 | `search_category_keywords` + `search_brand_keywords` JOIN | "진스" 같은 카테고리+브랜드 중의어 |
| 품절 상품 노출 | `product_displays` 재고 상태 컬럼 | 기본 필터 없어 노출 가능성 있음 |
| 브랜드 편중도 | `search_keyword_rankings` brand_id 분포 | 특정 브랜드 독점 여부 |
| 클릭률 상관성 | `search_logs` 클릭 패턴 | 노출 순위와 실제 클릭 일치도 |
| 오타 허용도 | 평가 가능하나 개선 불가 | Fuzzy 미적용 상태라 결과 0건 예상 |

---

## 7. 개선 우선순위 요약

| 순위 | 항목 | 난이도 | 영향도 |
|------|------|--------|--------|
| 1 | 품절 상품 기본 필터 추가 | 낮음 | 높음 |
| 2 | decompound_mode 실제값 확인 및 문서 정정 | 낮음 | 중간 |
| 3 | 쿼리 토크나이징 활성화 | 중간 | 높음 |
| 4 | Fuzzy Search 도입 | 중간 | 중간 |
