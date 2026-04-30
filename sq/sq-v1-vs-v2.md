# sq v1 vs v2 점수 체계 비교

> 작성일: 2026-04-30  
> v2 적용 파일: `sq-v2` (sq를 복제 후 수정)

---

## 1. 점수 항목 구조 비교

| # | v1 항목 | 배점 | v2 항목 | 배점 | 변경 이유 |
|---|--------|-----|--------|-----|---------|
| 1 | 결과 존재 여부 | **20점** | 결과 존재성 | **10점** | 가중치 재분배 (결과 있음 자체는 기본 전제) |
| 2 | 관련성 | **30점** | 결과 관련성 | **30점** | 유지 (단, 채점 방식 변경 — 아래 참고) |
| 3 | 이중 의도 커버리지 | **20점** | 의도 파악 정확도 | **20점** | 재정의 (유형별 채점으로 변경) |
| 4 | 상위 노출 적절성 | **15점** | 상위 노출 품질 | **20점** | 가중치 상향 (사용자 경험에 직결) |
| 5 | 품절 상품 노출 | **15점** | 품절 상품 노출 | **5점** | 가중치 하향 (인프라 이슈, 알고리즘과 분리) |
| 6 | _(없음)_ | — | 검색 범위 적절성 | **15점** | **신규 추가** — 발골 성공 여부 명시적 측정 |
| | **합계** | **100점** | **합계** | **100점** | |

---

## 2. 핵심 변경 사항 상세

### [A1] FALLBACK 감지 기준 수정

| 구분 | v1 (기존) | v2 (수정) |
|-----|---------|---------|
| 감지 조건 | extracted_* 모두 없음 AND `total_count > 1000` | extracted_* 모두 없음 AND `total_count > 2000` |
| 처리 방식 | **F등급 강제, 모든 점수 0점** | POSSIBLE_FALLBACK 표시 후 **채점 계속** (F강제 없음) |
| segment 값 | `"FALLBACK"` | `"POSSIBLE_FALLBACK"` |
| 평균 점수 집계 | FALLBACK은 평균 제외 | POSSIBLE_FALLBACK은 평균에 **포함** |

**왜 바꿨나:**  
백엔드 실제 코드(`search_products_service.py`)의 Tier 2 fallback은 `result_count == 0`일 때만 발동합니다. `total_count > 1000`은 백엔드 어디에도 없는 기준이라 v1이 정상 키워드를 F등급으로 잘못 처리하고 있었습니다.

---

### [A2] 이중 의도 → 의도 파악 정확도 (채점 방식 전면 개편)

| 구분 | v1 (기존) | v2 (수정) |
|-----|---------|---------|
| 조건 | DB에 category + brand 둘 다 있으면 이중 의도 | API result_query 필드로 쿼리 유형 판별 |
| 브랜드+카테고리 동시 | 결과에 양쪽 모두 포함해야 만점 | **카테고리 우선 처리** — 유형 B로 카테고리만 채점 |
| 채점 단위 | brand 커버리지 10점 + category 커버리지 10점 | 유형별(A/B/C/D/E) 독립 평가 |
| ETC 타입 | 단일의도로 20점 처리 | 0점 + `ETC_TYPE` 진단 |

**왜 바꿨나:**  
백엔드 `token_classifier.py`는 브랜드와 카테고리가 충돌할 때 **카테고리를 우선**하고 브랜드를 제거합니다. v1은 이를 모르고 "브랜드 결과 없음"으로 감점했습니다.

**v2 쿼리 유형 분류:**
- 유형 A: 브랜드 쿼리 (extracted_brands 있음, categories 없거나 충돌로 제거)
- 유형 B: 카테고리 쿼리 (extracted_categories 있음)
- 유형 C: 색상 쿼리 (extracted_colors만 있음)
- 유형 D: 복합 쿼리 (여러 타입 공존)
- 유형 E: ETC 쿼리 (extracted 모두 없음) → 0점

---

### [A3] 관련성 채점 방식 개선

| 구분 | v1 (기존) | v2 (수정) |
|-----|---------|---------|
| extracted_brands 있을 때 | **자동 relevance_ratio = 1.0** | LLM이 각 상품 직접 Y/N 판단 |
| 기준 | 브랜드 발골 성공 = 관련성 만점 가정 | 발골 성공과 관련성 **독립 평가** |
| 문자열 매칭 | 의도 불명확 시 name에 키워드 포함이면 Y | 포함 여부는 보조 기준 (단독 판단 금지) |

**왜 바꿨나:**  
"브랜드 발골 성공" ≠ "검색 결과가 관련 있음". 브랜드 필터 내에서도 나머지 토큰의 relevance에 따라 품질이 달라집니다. v1은 발골 성공 시 무조건 만점을 주어 품질 차이를 숨기고 있었습니다.

---

### [A4] ZERO_RESULT 경로 세분화

| 구분 | v1 (기존) | v2 (수정) |
|-----|---------|---------|
| 처리 방식 | 단순 `ZERO_RESULT` | `ZERO_UNRECOGNIZED` / `ZERO_NO_MATCH` 구분 |
| ZERO_UNRECOGNIZED | 없음 | extracted_* 모두 비어있음 → 키워드 사전 미등록 |
| ZERO_NO_MATCH | 없음 | extracted_* 있었지만 결과 0 → 매핑 문제 |
| 수정 방향 | 동일 처리 | 원인에 따라 다른 수정 액션 |

**왜 바꿨나:**  
수정 방향이 완전히 다릅니다:
- ZERO_UNRECOGNIZED → `search_keywords` INSERT 필요
- ZERO_NO_MATCH → entity 매핑 조정 or 유사어 추가 필요

---

### [B1] API 파라미터 정리

| 구분 | v1 (기존) | v2 (수정) |
|-----|---------|---------|
| SQ_SEARCH_PARAMS | `page=1&limit=50&step=0&search_source=POPULAR_KEYWORD` | `page=1&limit=50` |

**왜 바꿨나:**  
백엔드 API 스키마(`GetSearchProductResultsRequest`)에 `step`, `search_source` 파라미터가 존재하지 않습니다. Django Ninja가 이를 조용히 무시하므로 제거해도 동작에 영향 없습니다.

---

## 3. scores.json 출력 구조 비교

| 필드 | v1 | v2 |
|-----|----|----|
| breakdown 키 | `존재여부`, `관련성`, `이중의도`, `상위노출`, `품절노출` | `결과존재성`, `검색범위적절성`, `의도파악정확도`, `결과관련성`, `상위노출품질`, `품절노출` |
| segment 값 | `FALLBACK` / `ZERO_RESULT` / `GENERAL` | `POSSIBLE_FALLBACK` / `ZERO_RESULT` / `GENERAL` |
| 진단 | `diagnosis` (단일 문자열) | `diagnosis_codes` (배열) + `diagnosis` (서술) |
| 추가 필드 | — | `keyword_type`, `has_color`, `query_type`, `diagnosis_codes` |
| dual_intent 필드 | `dual_intent: boolean` | 제거 (query_type으로 대체) |

---

## 4. 리포트 집계 방식 비교

| 구분 | v1 | v2 |
|-----|----|----|
| 평균 점수 계산 대상 | GENERAL만 | GENERAL + POSSIBLE_FALLBACK |
| FALLBACK/POSSIBLE_FALLBACK | 평균 제외, F등급 | 평균 포함, 실제 채점 점수 사용 |
| 진단 분류 | 자유 문자열 기반 | diagnosis_codes 코드 기반 (표준화) |
| ZERO_RESULT 분류 | 단일 항목 | UNRECOGNIZED / NO_MATCH 구분 |
| CSV 헤더 | `dual_intent` 포함 | breakdown 6개 컬럼, `query_type`, `diagnosis_codes` |

---

## 5. 등급 기준

v1과 v2 **동일** (변경 없음):

| 점수 | 등급 |
|------|------|
| 85~100 | A |
| 70~84  | B |
| 50~69  | C |
| 30~49  | D |
| 0~29   | F |

---

## 6. 마이그레이션 노트

v1 리포트(scores.json)와 v2 리포트는 **점수 항목 구조가 다르므로 직접 비교 불가**합니다.

v2 최초 실행 후 baseline을 새로 확립하고, 이후 sq-fix → sq-v2 재실행으로 개선도를 측정하세요.

---

*참고 문서: `/Users/hwangdahee/development/tmux/sq-fix/PLAN.md` §2(교차 분석) §3(점수 체계 재설계)*
