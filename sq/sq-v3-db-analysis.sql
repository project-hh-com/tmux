-- ============================================================
-- sq-v3 사전 분석 쿼리 — read-only replica 전용
-- 목적: keyword_fixer 구현 전 수정 규모 파악
-- 실행: PGPASSWORD="..." psql -h HOST -U danble_read_only -d danble -p 5432 -f sq-v3-db-analysis.sql
-- ============================================================

-- ──────────────────────────────────────────────────────────────
-- [0] 전체 키워드 현황
-- ──────────────────────────────────────────────────────────────
\echo '========================================'
\echo '[0] 전체 키워드 현황'
\echo '========================================'

SELECT
  COUNT(*)                                                          AS 전체_키워드수,
  COUNT(*) FILTER (WHERE result_product_count = 0)                 AS 결과0건_키워드수,
  ROUND(
    COUNT(*) FILTER (WHERE result_product_count = 0) * 100.0
    / NULLIF(COUNT(*), 0), 2
  )                                                                 AS 결과0건_비율_PCT,
  COUNT(*) FILTER (WHERE keyword_type = 'ETC')                     AS ETC타입_키워드수,
  COUNT(*) FILTER (WHERE keyword_type = 'BRAND')                   AS BRAND타입_키워드수,
  COUNT(*) FILTER (WHERE keyword_type = 'CATEGORY')                AS CATEGORY타입_키워드수,
  COUNT(*) FILTER (WHERE keyword_type = 'COLOR')                   AS COLOR타입_키워드수
FROM search_keywords
WHERE is_deleted = false;


-- ──────────────────────────────────────────────────────────────
-- [1] ZERO_RESULT — 결과 0건 키워드 분석
-- ──────────────────────────────────────────────────────────────
\echo ''
\echo '========================================'
\echo '[1] ZERO_RESULT — 결과 0건 키워드 현황'
\echo '========================================'

-- [1-A] keyword_type별 분포
\echo '--- [1-A] 결과 0건 keyword_type별 분포 ---'
SELECT
  keyword_type,
  COUNT(*) AS 건수,
  ROUND(COUNT(*) * 100.0 / NULLIF(SUM(COUNT(*)) OVER (), 0), 2) AS 비율_PCT
FROM search_keywords
WHERE is_deleted = false
  AND result_product_count = 0
GROUP BY keyword_type
ORDER BY 건수 DESC;

-- [1-B] ZERO_RESULT rank 상위 30개 (수정 우선순위)
\echo '--- [1-B] ZERO_RESULT rank 상위 30개 ---'
SELECT
  rank,
  keyword,
  normalized_keyword,
  keyword_type,
  category_main,
  EXISTS(SELECT 1 FROM search_brand_keywords    WHERE search_keyword_id = sk.id) AS has_brand_mapping,
  EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id) AS has_category_mapping,
  EXISTS(SELECT 1 FROM search_color_keywords    WHERE search_keyword_id = sk.id) AS has_color_mapping,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SAME')  AS same_count,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SIMILAR') AS similar_count
FROM search_keywords sk
WHERE is_deleted = false
  AND result_product_count = 0
ORDER BY rank ASC NULLS LAST
LIMIT 30;

-- [1-C] ZERO_RESULT 중 매핑이 하나도 없는 키워드 (ZERO_UNRECOGNIZED 후보)
\echo '--- [1-C] ZERO_RESULT 중 발골사전 매핑이 전혀 없는 키워드 수 ---'
SELECT COUNT(*) AS ZERO_UNRECOGNIZED_후보수
FROM search_keywords sk
WHERE is_deleted = false
  AND result_product_count = 0
  AND NOT EXISTS(SELECT 1 FROM search_brand_keywords    WHERE search_keyword_id = sk.id)
  AND NOT EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id)
  AND NOT EXISTS(SELECT 1 FROM search_color_keywords    WHERE search_keyword_id = sk.id);

-- [1-D] ZERO_RESULT 중 SAME/SIMILAR relation도 없는 키워드 (동의어 추가로 구제 불가)
\echo '--- [1-D] ZERO_RESULT + 동의어 없음 (순수 미등록) ---'
SELECT COUNT(*) AS 순수_ZERO수
FROM search_keywords sk
WHERE is_deleted = false
  AND result_product_count = 0
  AND NOT EXISTS(
    SELECT 1 FROM search_keyword_relations
    WHERE source_keyword_id = sk.id
  );


-- ──────────────────────────────────────────────────────────────
-- [2] ETC_TYPE — keyword_type 개선 후보
-- ──────────────────────────────────────────────────────────────
\echo ''
\echo '========================================'
\echo '[2] ETC_TYPE — keyword_type 개선 후보'
\echo '========================================'

-- [2-A] ETC 타입 중 결과 있는 키워드 (type 변경 시 정확도 개선 가능)
\echo '--- [2-A] ETC 타입 + 결과 있는 키워드 수 ---'
SELECT
  COUNT(*) AS ETC_결과있음_건수,
  COUNT(*) FILTER (WHERE result_product_count > 0 AND result_product_count <= 10) AS 결과1_10건,
  COUNT(*) FILTER (WHERE result_product_count > 10 AND result_product_count <= 100) AS 결과11_100건,
  COUNT(*) FILTER (WHERE result_product_count > 100) AS 결과100건초과
FROM search_keywords
WHERE is_deleted = false
  AND keyword_type = 'ETC';

-- [2-B] ETC 타입 rank 상위 20개 (category_main 참고)
\echo '--- [2-B] ETC 타입 rank 상위 20개 ---'
SELECT
  rank,
  keyword,
  normalized_keyword,
  category_main,
  result_product_count,
  EXISTS(SELECT 1 FROM search_brand_keywords    WHERE search_keyword_id = sk.id) AS has_brand_mapping,
  EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id) AS has_category_mapping
FROM search_keywords sk
WHERE is_deleted = false
  AND keyword_type = 'ETC'
ORDER BY rank ASC NULLS LAST
LIMIT 20;

-- [2-C] ETC 중 search_brand_keywords 매핑이 있는 경우 (keyword_type만 BRAND로 바꾸면 됨)
\echo '--- [2-C] ETC + brand 매핑 있음 (keyword_type만 BRAND로 변경하면 됨) ---'
SELECT
  sk.rank,
  sk.keyword,
  sk.keyword_type,
  sbk.brand_id,
  sk.result_product_count
FROM search_keywords sk
JOIN search_brand_keywords sbk ON sbk.search_keyword_id = sk.id
WHERE sk.is_deleted = false
  AND sk.keyword_type = 'ETC'
ORDER BY sk.rank ASC NULLS LAST
LIMIT 20;

-- [2-D] ETC 중 search_category_keywords 매핑이 있는 경우
\echo '--- [2-D] ETC + category 매핑 있음 (keyword_type만 CATEGORY로 변경하면 됨) ---'
SELECT
  sk.rank,
  sk.keyword,
  sk.keyword_type,
  sck.product_type,
  sk.result_product_count
FROM search_keywords sk
JOIN search_category_keywords sck ON sck.search_keyword_id = sk.id
WHERE sk.is_deleted = false
  AND sk.keyword_type = 'ETC'
ORDER BY sk.rank ASC NULLS LAST
LIMIT 20;


-- ──────────────────────────────────────────────────────────────
-- [3] NO_SYNONYM — SAME 동의어 없는 키워드
-- ──────────────────────────────────────────────────────────────
\echo ''
\echo '========================================'
\echo '[3] NO_SYNONYM — SAME 동의어 없는 키워드'
\echo '========================================'

-- [3-A] 전체 현황
\echo '--- [3-A] 동의어(SAME) 커버리지 현황 ---'
SELECT
  COUNT(*)                                                             AS 전체_키워드수,
  COUNT(*) FILTER (WHERE same_count = 0)                              AS SAME없음_키워드수,
  COUNT(*) FILTER (WHERE similar_count = 0)                           AS SIMILAR없음_키워드수,
  COUNT(*) FILTER (WHERE same_count = 0 AND similar_count = 0)        AS 관계없음_키워드수,
  ROUND(COUNT(*) FILTER (WHERE same_count = 0) * 100.0 / COUNT(*), 2) AS SAME없음_비율_PCT
FROM (
  SELECT
    sk.id,
    COUNT(*) FILTER (WHERE skr.relation_type = 'SAME')    AS same_count,
    COUNT(*) FILTER (WHERE skr.relation_type = 'SIMILAR') AS similar_count
  FROM search_keywords sk
  LEFT JOIN search_keyword_relations skr ON skr.source_keyword_id = sk.id
  WHERE sk.is_deleted = false
    AND sk.result_product_count > 0
  GROUP BY sk.id
) t;

-- [3-B] SAME 없고 rank 상위 + 결과 있는 키워드 (동의어 추가 우선순위)
\echo '--- [3-B] SAME 없음 + 결과 있음 + rank 상위 30개 ---'
SELECT
  sk.rank,
  sk.keyword,
  sk.keyword_type,
  sk.result_product_count,
  sk.category_main,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SIMILAR') AS similar_count
FROM search_keywords sk
WHERE sk.is_deleted = false
  AND sk.result_product_count > 0
  AND NOT EXISTS(
    SELECT 1 FROM search_keyword_relations
    WHERE source_keyword_id = sk.id AND relation_type = 'SAME'
  )
ORDER BY sk.rank ASC NULLS LAST
LIMIT 30;

-- [3-C] 현재 SAME 관계 등록 현황 (전체 규모 파악)
\echo '--- [3-C] search_keyword_relations 전체 현황 ---'
SELECT
  relation_type,
  COUNT(*)          AS 전체_관계수,
  COUNT(DISTINCT source_keyword_id) AS 소스_키워드수
FROM search_keyword_relations
GROUP BY relation_type
ORDER BY relation_type;


-- ──────────────────────────────────────────────────────────────
-- [4] POSSIBLE_FALLBACK 후보 — 발골사전 미등록 CATEGORY 키워드
-- ──────────────────────────────────────────────────────────────
\echo ''
\echo '========================================'
\echo '[4] POSSIBLE_FALLBACK 후보'
\echo '========================================'

-- [4-A] CATEGORY 타입인데 search_category_keywords 없는 키워드
\echo '--- [4-A] CATEGORY keyword + category 매핑 없음 (POSSIBLE_FALLBACK 발생 원인) ---'
SELECT COUNT(*) AS CATEGORY_매핑없음_건수
FROM search_keywords sk
WHERE is_deleted = false
  AND keyword_type = 'CATEGORY'
  AND NOT EXISTS(
    SELECT 1 FROM search_category_keywords
    WHERE search_keyword_id = sk.id
  );

-- [4-B] 상위 20개 목록
\echo '--- [4-B] CATEGORY 매핑 없음 rank 상위 20개 ---'
SELECT
  sk.rank,
  sk.keyword,
  sk.result_product_count,
  sk.category_main
FROM search_keywords sk
WHERE is_deleted = false
  AND keyword_type = 'CATEGORY'
  AND NOT EXISTS(
    SELECT 1 FROM search_category_keywords
    WHERE search_keyword_id = sk.id
  )
ORDER BY sk.rank ASC NULLS LAST
LIMIT 20;

-- [4-C] BRAND 타입인데 search_brand_keywords 없는 키워드
\echo '--- [4-C] BRAND keyword + brand 매핑 없음 ---'
SELECT COUNT(*) AS BRAND_매핑없음_건수
FROM search_keywords sk
WHERE is_deleted = false
  AND keyword_type = 'BRAND'
  AND NOT EXISTS(
    SELECT 1 FROM search_brand_keywords
    WHERE search_keyword_id = sk.id
  );


-- ──────────────────────────────────────────────────────────────
-- [5] 수정 가능 규모 종합 (keyword_fixer 작업량 추정)
-- ──────────────────────────────────────────────────────────────
\echo ''
\echo '========================================'
\echo '[5] 수정 가능 규모 종합 (fix_type별 예상 건수)'
\echo '========================================'

SELECT
  'INSERT_KEYWORD (ZERO_UNRECOGNIZED)' AS fix_type,
  COUNT(*) AS 예상_건수
FROM search_keywords sk
WHERE is_deleted = false
  AND result_product_count = 0
  AND NOT EXISTS(SELECT 1 FROM search_brand_keywords    WHERE search_keyword_id = sk.id)
  AND NOT EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id)
  AND NOT EXISTS(SELECT 1 FROM search_color_keywords    WHERE search_keyword_id = sk.id)

UNION ALL

SELECT
  'ADD_SYNONYM — SAME 동의어 추가 후보',
  COUNT(*)
FROM search_keywords sk
WHERE is_deleted = false
  AND result_product_count > 0
  AND NOT EXISTS(
    SELECT 1 FROM search_keyword_relations
    WHERE source_keyword_id = sk.id AND relation_type = 'SAME'
  )

UNION ALL

SELECT
  'FIX_KEYWORD_TYPE — ETC→BRAND (brand 매핑 있음)',
  COUNT(DISTINCT sk.id)
FROM search_keywords sk
JOIN search_brand_keywords sbk ON sbk.search_keyword_id = sk.id
WHERE sk.is_deleted = false AND sk.keyword_type = 'ETC'

UNION ALL

SELECT
  'FIX_KEYWORD_TYPE — ETC→CATEGORY (category 매핑 있음)',
  COUNT(DISTINCT sk.id)
FROM search_keywords sk
JOIN search_category_keywords sck ON sck.search_keyword_id = sk.id
WHERE sk.is_deleted = false AND sk.keyword_type = 'ETC'

UNION ALL

SELECT
  'FIX_CATEGORY_MAPPING — CATEGORY 타입 매핑 없음',
  COUNT(*)
FROM search_keywords sk
WHERE is_deleted = false
  AND keyword_type = 'CATEGORY'
  AND NOT EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id)

UNION ALL

SELECT
  'FIX_BRAND_MAPPING — BRAND 타입 매핑 없음',
  COUNT(*)
FROM search_keywords sk
WHERE is_deleted = false
  AND keyword_type = 'BRAND'
  AND NOT EXISTS(SELECT 1 FROM search_brand_keywords WHERE search_keyword_id = sk.id)

ORDER BY 예상_건수 DESC;
