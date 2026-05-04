# skq — Search Keyword Quality

검색 키워드 품질을 자동으로 진단하고 개선하는 6-Phase 멀티에이전트 워크플로.

```bash
skq                              # 전체 키워드 대상으로 실행
skq "브랜드 카테고리 키워드 개선"  # 범위를 지정해 실행
```

---

## 설치

### 1단계 — 의존성 확인

skq 실행에 필요한 도구:

| 도구 | 용도 | 설치 방법 |
|------|------|----------|
| **claude CLI** | 에이전트 실행 엔진 | `npm install -g @anthropic-ai/claude-code` |
| **psql** | DB 쿼리 실행 | `brew install libpq` |
| **tmux** | 에이전트 패널 관리 (권장) | `brew install tmux` |
| **Node.js 18+** | claude CLI 런타임 | `brew install node` |

```bash
# 설치 확인
claude --version
psql --version
tmux -V
node --version
```

### 2단계 — skq-setup 실행

```bash
cd /path/to/tmux/skq
bash skq-setup
```

setup이 순서대로 처리하는 것:

1. **DB 자격증명** — `~/.config/sq/db.env` 생성 (sq와 공유, 이미 있으면 재사용)
2. **psql 확인** — 없으면 `brew install libpq` 자동 실행
3. **claude CLI 확인** — 없으면 설치 안내 후 종료
4. **DB 연결 테스트** — 6개 테이블 접근 확인
5. **PATH 등록** — `~/.local/bin/skq` 심볼릭 링크 생성

```bash
# setup 완료 후 PATH 반영
source ~/.zshrc

# 동작 확인
skq --help  # 또는 그냥 skq
```

### 3단계 — 에이전트 문서 파일 확인

skq 에이전트들이 실행 중 직접 읽는 문서 파일이 있어야 한다.

```
skq/docs/search-pipeline.md   # 검색 파이프라인 구조 설명
skq/docs/db-schema.md         # 테이블 스키마 상세
```

없으면 에이전트가 컨텍스트 없이 실행되어 품질이 낮아진다.

---

## 사전 조건 요약

```
✅ claude CLI 설치 및 로그인 (claude login)
✅ psql 설치 (brew install libpq)
✅ tmux 설치 (brew install tmux) — 권장, 없어도 동작
✅ ~/.config/sq/db.env 존재 (skq-setup이 생성)
✅ danble VPN 연결 상태 (RDS 접근 필요)
✅ skq/docs/search-pipeline.md 존재
✅ skq/docs/db-schema.md 존재
```

---

## 개요

skq는 검색 DB를 분석해 품질 문제를 찾고, 개선 SQL을 자동 생성한다.
생성된 SQL은 사람이 검토한 뒤 별도로 적용한다.

**진단 코드 5종**

| 코드 | 의미 |
|------|------|
| `ZERO_RESULT` | 검색 결과 0건 키워드 |
| `ETC_TYPE` | 키워드 타입이 `ETC`로 잘못 분류된 경우 |
| `NO_SYNONYM` | 유의어가 없는 주요 키워드 |
| `POSSIBLE_FALLBACK` | 앵커 없이 폴백 결과만 노출 |
| `WRONG_PRIORITY` | 우선순위 설정 오류 |

---

## 워크플로 (6-Phase)

```
Phase A  Discovery    DB 기반 개선 대상 키워드 자동 발굴
Phase B  Analysis     각 키워드별 진단 코드 + 수정 방향 제안
Phase C  Plan Debate  수정 방향 도메인 적합성 토론 (Red / Blue / Judge)
Phase D  Propose      승인된 플랜 기반 병렬 SQL 생성 (에이전트 5개 동시 실행)
Phase E  Ship-Ready   최종 SQL 패키징 + 매니페스트 생성
Phase F  Validate     예상 개선도 추정 + 리포트 (비동기)
```

Phase A–C, E는 에이전트 1개 직렬 실행, Phase D는 5개 병렬, Phase F는 백그라운드 비동기 실행.

---

## 실행 환경

**tmux 세션 안에서 실행 (권장)**

각 Phase마다 에이전트 패널이 오른쪽에 생성되고, Phase가 끝나면 자동 정리된다.
Phase D에서는 패널 5개가 세로로 쌓여 병렬 진행 상황을 한눈에 확인할 수 있다.

```
┌──────────────────┬──────────────────────┐
│                  │  1️⃣ D1_zero_fixer     │
│  orchestrator    ├──────────────────────┤
│  (main pane)     │  2️⃣ D2_type_fixer     │
│                  ├──────────────────────┤
│                  │  3️⃣ D3_synonym_fixer  │
│                  ├──────────────────────┤
│                  │  4️⃣ D4_anchor_fixer   │
│                  ├──────────────────────┤
│                  │  5️⃣ D5_priority_fixer │
└──────────────────┴──────────────────────┘
           Phase D 실행 중 레이아웃
```

**tmux 밖에서 실행**

백그라운드 tmux 세션으로 자동 전환된다. 진행 상황 확인이 어려우므로 tmux 안에서 실행을 권장한다.

---

## DB 접근 권한

| 구분 | 계정 | 용도 |
|------|------|------|
| skq | `danble_read_only` | Phase A~F 분석 쿼리 (SELECT만) |
| SQL 적용 | 별도 쓰기 계정 | ship.sql 수동 적용 시 |

skq는 DB를 직접 수정하지 않는다. 생성된 `ship.sql`만 별도 검토 후 적용한다.

---

## 출력물

실행 결과는 `docs/reports/skq-{DATE}/` 에 저장된다.

```
docs/reports/skq-20260504-143022/
├── phase-a-discovery.md     # 발굴된 키워드 목록
├── phase-b-analysis.md      # 진단 결과
├── phase-c-debate.md        # Red/Blue/Judge 토론 기록
├── d1_zero_fixer.sql        # Phase D 개별 SQL
├── d2_type_fixer.sql
├── d3_synonym_fixer.sql
├── d4_anchor_fixer.sql
├── d5_priority_fixer.sql
├── ship.sql                 # 최종 통합 SQL (Phase E 패키징)
├── ship-manifest.md         # 변경 요약 + 롤백 SQL
└── phase-f-validate.md      # 예상 개선도 리포트 (비동기 생성)
```

---

## SQL 적용 순서

skq가 생성한 `ship.sql` 내부 적용 순서 (Phase E 기준):

1. `UPDATE_PRIORITY` — 우선순위 수정 (토큰 매칭 기준 먼저 확정)
2. `UPDATE_KEYWORD_TYPE` — 키워드 타입 수정
3. `INSERT_SYNONYM` — 유의어 추가
4. `UPDATE_ANCHOR` — 발골사전 연결

---

## 파일 구조

```
skq/
├── skq                        # 메인 실행 파일
├── skq-setup                  # 초기 설치 스크립트
├── skq-overview.html          # 시각적 워크플로 문서
├── README.md                  # 이 파일
├── docs/
│   ├── search-pipeline.md     # 에이전트용 파이프라인 문서 (필수)
│   ├── db-schema.md           # 에이전트용 스키마 문서 (필수)
│   └── reports/               # 실행 결과 저장 (자동 생성)
└── .agent/                    # 실행 중 임시 파일 (자동 생성, git 무시)
    └── skq-{DATE}/
        ├── pane_ids.txt
        ├── phase_d_shared/    # Phase D 에이전트 간 조율용 공유 디렉토리
        ├── prompt_phase_*.txt
        └── run_*.sh
```

---

## 트러블슈팅

**DB 연결 실패**
```bash
# VPN 연결 확인 후
source ~/.config/sq/db.env
psql -h $PGHOST -U $PGUSER -d $PGDATABASE -p $PGPORT -c "SELECT 1;"
```

**claude CLI 인증 오류**
```bash
claude login
```

**PATH에 skq가 없을 때**
```bash
source ~/.zshrc
# 또는
export PATH="$HOME/.local/bin:$PATH"
```

**처음부터 재설정**
```bash
rm ~/.config/sq/db.env
bash skq-setup
```

---

## 관련 명령어

- `sq` — 개별 키워드 검색 품질 조회 / 분석
- `skq-setup` — 초기 환경 설정
