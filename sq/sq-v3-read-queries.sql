-- ============================================================
-- sq-v3 실행 시 read-only DB 쿼리 모음
--
-- 역할: sq-v3 에이전트(runner / scorer / keyword_fixer)가
--       실행 중에 사용하는 read-only 조회 쿼리입니다.
--       최종 분석 리포트 외에 keyword_fixer가 올바른 SQL을
--       생성하기 위해 필요한 컨텍스트를 DB에서 읽어옵니다.
--
-- 실행 방법 (sq-v3 에이전트 내부에서 psql 환경변수 이용):
--   PGPASSWORD="${PGPASSWORD}" psql \
--     -h "${PGHOST}" -U "${PGUSER}" -d "${PGDATABASE}" -p "${PGPORT}" \
--     --no-password -t -A -F',' -c "..."
--
-- ⚠️  현재는 read-only 계정(danble_read_only)으로만 실행합니다.
--     아래 각 쿼리 결과를 JSON/CSV 파일로 저장해 두면,
--     나중에 write 권한을 가진 계정으로 전환 시
--     keyword_fixer가 해당 파일을 참조해 INSERT/UPDATE SQL을
--     자동 생성할 수 있습니다.
-- ============================================================


-- ============================================================
-- PHASE 1 — Runner 입력 키워드 수집
-- (runner 에이전트가 "어떤 키워드로 검색 API를 호출할지" 결정)
-- ============================================================

-- ── [R-1] ZERO_RESULT 키워드 (결과 0건 — 수정 효과 가장 큼)
-- 저장 경로: ${FLAG_DIR}/runner_zero_result.csv
-- ⚠️ 나중에 write 권한 확보 시:
--    이 목록이 keyword_fixer의 INSERT 대상 seed가 됩니다.
SELECT
  sk.id             AS keyword_id,
  sk.keyword,
  sk.normalized_keyword,
  sk.keyword_type,
  sk.category_main,
  sk.rank,
  sk.result_product_count,
  EXISTS(SELECT 1 FROM search_brand_keywords    WHERE search_keyword_id = sk.id) AS has_brand_mapping,
  EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id) AS has_category_mapping,
  EXISTS(SELECT 1 FROM search_color_keywords    WHERE search_keyword_id = sk.id) AS has_color_mapping,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SAME')    AS same_count,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SIMILAR') AS similar_count
FROM search_keywords sk
WHERE sk.is_deleted = false
  AND sk.result_product_count = 0
ORDER BY sk.rank ASC NULLS LAST
LIMIT 150;


-- ── [R-2] ETC_TYPE 키워드 (keyword_type 변경으로 개선 가능)
-- 저장 경로: ${FLAG_DIR}/runner_etc_type.csv
-- ⚠️ 나중에 write 권한 확보 시:
--    keyword_type UPDATE + brand/category 매핑 INSERT 대상이 됩니다.
SELECT
  sk.id             AS keyword_id,
  sk.keyword,
  sk.normalized_keyword,
  sk.keyword_type,
  sk.category_main,
  sk.rank,
  sk.result_product_count,
  EXISTS(SELECT 1 FROM search_brand_keywords    WHERE search_keyword_id = sk.id) AS has_brand_mapping,
  EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id) AS has_category_mapping,
  (SELECT sbk.brand_id
   FROM search_brand_keywords sbk
   WHERE sbk.search_keyword_id = sk.id
   LIMIT 1) AS existing_brand_id,
  (SELECT sck.product_type
   FROM search_category_keywords sck
   WHERE sck.search_keyword_id = sk.id
   LIMIT 1) AS existing_product_type
FROM search_keywords sk
WHERE sk.is_deleted = false
  AND sk.keyword_type = 'ETC'
  AND sk.result_product_count > 0
ORDER BY sk.rank ASC NULLS LAST
LIMIT 100;


-- ── [R-3] NO_SYNONYM 키워드 (SAME 동의어 없음 — 동의어 추가로 결과 다양성 개선)
-- 저장 경로: ${FLAG_DIR}/runner_no_synonym.csv
-- ⚠️ 나중에 write 권한 확보 시:
--    search_keyword_relations INSERT (relation_type='SAME') 대상이 됩니다.
SELECT
  sk.id             AS keyword_id,
  sk.keyword,
  sk.normalized_keyword,
  sk.keyword_type,
  sk.category_main,
  sk.rank,
  sk.result_product_count,
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
LIMIT 100;


-- ── [R-4] POSSIBLE_FALLBACK 후보 (발골사전 미등록)
-- 저장 경로: ${FLAG_DIR}/runner_possible_fallback.csv
-- ⚠️ 나중에 write 권한 확보 시:
--    search_category_keywords 또는 search_brand_keywords INSERT 대상이 됩니다.
SELECT
  sk.id             AS keyword_id,
  sk.keyword,
  sk.normalized_keyword,
  sk.keyword_type,
  sk.category_main,
  sk.rank,
  sk.result_product_count
FROM search_keywords sk
WHERE sk.is_deleted = false
  AND sk.result_product_count > 0
  AND (
    -- CATEGORY 타입인데 category 매핑 없음
    (sk.keyword_type = 'CATEGORY'
     AND NOT EXISTS(SELECT 1 FROM search_category_keywords WHERE search_keyword_id = sk.id))
    OR
    -- BRAND 타입인데 brand 매핑 없음
    (sk.keyword_type = 'BRAND'
     AND NOT EXISTS(SELECT 1 FROM search_brand_keywords WHERE search_keyword_id = sk.id))
  )
ORDER BY sk.rank ASC NULLS LAST
LIMIT 100;


-- ============================================================
-- PHASE 2 — keyword_fixer 컨텍스트 조회
-- (scorer가 생성한 diagnosis_codes를 기반으로
--  keyword_fixer가 올바른 SQL을 생성하기 위해 필요한 정보)
-- ============================================================

-- ── [F-1] 특정 키워드의 전체 컨텍스트 조회
-- 사용법: keyword_fixer 에이전트가 각 진단 키워드마다 이 쿼리를 실행합니다.
-- :kw_id 자리에 search_keywords.id 값을 바인딩하세요.
-- ⚠️ 이 쿼리 결과가 fix_search_keywords.sql 생성의 근거 데이터가 됩니다.
SELECT
  sk.id,
  sk.keyword,
  sk.normalized_keyword,
  sk.keyword_type,
  sk.category_main,
  sk.result_product_count,
  sk.rank,
  -- brand 매핑
  (SELECT json_agg(json_build_object('brand_id', sbk.brand_id))
   FROM search_brand_keywords sbk
   WHERE sbk.search_keyword_id = sk.id)             AS brand_mappings,
  -- category 매핑
  (SELECT json_agg(json_build_object(
     'product_type',              sck.product_type,
     'search_scope_product_type', sck.search_scope_product_type,
     'product_midtype_ids',       sck.product_midtype_ids,
     'product_subtype_ids',       sck.product_subtype_ids,
     'requires_name_search',      sck.requires_name_search
   ))
   FROM search_category_keywords sck
   WHERE sck.search_keyword_id = sk.id)             AS category_mappings,
  -- 현재 동의어/유사어
  (SELECT json_agg(json_build_object(
     'target_keyword_id', skr.target_keyword_id,
     'target_keyword',    tk.keyword,
     'relation_type',     skr.relation_type,
     'relation_score',    skr.relation_score
   ))
   FROM search_keyword_relations skr
   JOIN search_keywords tk ON tk.id = skr.target_keyword_id
   WHERE skr.source_keyword_id = sk.id)             AS relations_outgoing,
  -- 역방향 관계 (이 키워드를 target으로 가리키는 것)
  (SELECT json_agg(json_build_object(
     'source_keyword_id', skr.source_keyword_id,
     'source_keyword',    sk2.keyword,
     'relation_type',     skr.relation_type
   ))
   FROM search_keyword_relations skr
   JOIN search_keywords sk2 ON sk2.id = skr.source_keyword_id
   WHERE skr.target_keyword_id = sk.id)             AS relations_incoming
FROM search_keywords sk
WHERE sk.id = :kw_id;  -- keyword_fixer가 각 키워드마다 바인딩


-- ── [F-2] 브랜드 이름으로 brand_id 조회
-- 사용법: ZERO_UNRECOGNIZED 키워드가 브랜드명일 때
--         keyword_fixer가 올바른 brand_id를 찾기 위해 사용합니다.
-- ⚠️ 나중에 write 권한 확보 시:
--    이 brand_id를 사용해 search_brand_keywords INSERT를 생성합니다.
SELECT
  b.id      AS brand_id,
  b.name,
  b.name_kor,
  b.slug
FROM brands b  -- 실제 테이블명 확인 필요 (brands 또는 brand)
WHERE LOWER(b.name)     LIKE LOWER('%' || :brand_name || '%')
   OR LOWER(b.name_kor) LIKE LOWER('%' || :brand_name || '%')
LIMIT 10;


-- ── [F-3] 카테고리 product_type 목록 조회
-- 사용법: ZERO_UNRECOGNIZED/ETC_TYPE 키워드가 카테고리명일 때
--         올바른 product_type 값을 찾기 위해 사용합니다.
-- ⚠️ 나중에 write 권한 확보 시:
--    이 product_type을 사용해 search_category_keywords INSERT를 생성합니다.
SELECT DISTINCT
  product_type,
  COUNT(*) AS 매핑된_키워드수
FROM search_category_keywords
GROUP BY product_type
ORDER BY 매핑된_키워드수 DESC;


-- ── [F-4] 유사 키워드 검색 (동의어 관계 생성 시 target_keyword_id 확인용)
-- 사용법: NO_SYNONYM 키워드에 동의어를 추가할 때
--         target 키워드가 search_keywords에 이미 있는지 확인합니다.
-- ⚠️ 나중에 write 권한 확보 시:
--    여기서 찾은 target_keyword_id로 search_keyword_relations INSERT를 생성합니다.
SELECT
  id         AS keyword_id,
  keyword,
  normalized_keyword,
  keyword_type,
  result_product_count,
  rank
FROM search_keywords
WHERE (
  LOWER(keyword) = LOWER(:target_keyword)
  OR LOWER(normalized_keyword) = LOWER(:target_keyword)
)
AND is_deleted = false
LIMIT 5;


-- ── [F-5] relation_score 범위 파악 (INSERT 시 적절한 score 값 결정용)
-- ⚠️ 나중에 write 권한 확보 시:
--    새로 INSERT할 relation_score 기준값으로 활용합니다.
SELECT
  relation_type,
  MIN(relation_score)                       AS 최솟값,
  MAX(relation_score)                       AS 최댓값,
  ROUND(AVG(relation_score)::numeric, 4)    AS 평균값,
  ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP
    (ORDER BY relation_score)::numeric, 4)  AS 중앙값
FROM search_keyword_relations
GROUP BY relation_type
ORDER BY relation_type;


-- ── [F-6] 같은 category_main끼리 묶인 키워드 조회 (동의어 후보 탐색용)
-- 사용법: 특정 키워드와 같은 category_main에 속하는 키워드를
--         동의어/유사어 후보로 참고합니다.
-- ⚠️ 나중에 write 권한 확보 시:
--    이 목록에서 적합한 pair를 선별해 search_keyword_relations INSERT를 생성합니다.
SELECT
  sk.id,
  sk.keyword,
  sk.normalized_keyword,
  sk.keyword_type,
  sk.result_product_count,
  sk.rank,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SAME') AS same_count
FROM search_keywords sk
WHERE sk.is_deleted = false
  AND sk.category_main = :category_main
  AND sk.keyword_type  = :keyword_type
ORDER BY sk.rank ASC NULLS LAST
LIMIT 30;


-- ============================================================
-- PHASE 3 — After 재측정용 키워드 재조회
-- (keyword_fixer가 SQL을 적용한 뒤 동일 키워드를 재검색해
--  before/after 비교 리포트를 만들기 위한 스냅샷)
-- ⚠️ 현재는 read-only이므로 실제 변경은 없습니다.
--    write 권한 확보 후 SQL 적용 → 이 쿼리로 result_product_count 변화 확인.
-- ============================================================

-- ── [A-1] 수정 대상 키워드의 현재 result_product_count 스냅샷
-- 저장 경로: ${FLAG_DIR}/snapshot_before_fix.csv
-- ⚠️ 나중에 write 권한으로 변경 적용 후
--    동일 쿼리를 snapshot_after_fix.csv 로 저장해 비교합니다.
SELECT
  sk.id,
  sk.keyword,
  sk.keyword_type,
  sk.result_product_count,
  sk.rank,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SAME')    AS same_count,
  (SELECT COUNT(*) FROM search_keyword_relations
   WHERE source_keyword_id = sk.id AND relation_type = 'SIMILAR') AS similar_count,
  NOW() AS snapshot_at
FROM search_keywords sk
WHERE sk.id = ANY(:keyword_ids)  -- keyword_fixer 수정 대상 ID 배열
ORDER BY sk.rank ASC NULLS LAST;
