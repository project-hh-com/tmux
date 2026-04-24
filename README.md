# ~/tmux

Claude Agent 기반 개발 자동화 커맨드 모음.

📖 **문서 사이트**: [hwangdahee.github.io/tmux](https://hwangdahee.github.io/tmux)

---

## 커맨드 목록

| 커맨드 | 상태 | 설명 |
|--------|------|------|
| [`ship`](./ship/) | ✅ Stable | 기획부터 PR까지 원커맨드 자동화 |
| `fix` | 🔜 Coming soon | 버그 수정 특화 |
| `review` | 🔜 Coming soon | PR 코드 리뷰 자동화 |

---

## 설치

### 사전 요구사항

```bash
brew install tmux
brew install gh && gh auth login
npm install -g @anthropic-ai/claude-code
```

### 1. 스크립트 설치

```bash
mkdir -p ~/.local/bin

# ship 설치
cp ship/ship ~/.local/bin/ship
chmod +x ~/.local/bin/ship
```

### 2. PATH 설정

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc

# 확인
which ship   # → /Users/[이름]/.local/bin/ship
```

### 3. Claude Code 설정

`~/.claude/settings.json`에 아래 내용 추가:

```json
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "permissions": {
    "allow": [
      "Read(**)", "Write(**)", "Edit(**)",
      "Bash(git *)", "Bash(gh *)", "Bash(npm *)", "Bash(npx *)",
      "Bash(tmux *)", "Bash(node *)", "Bash(ls *)", "Bash(mkdir *)",
      "Bash(touch *)", "Bash(find *)", "Bash(grep *)"
    ]
  }
}
```

---

## 사용법

### ship

```bash
# tmux 세션 안에서 실행 (패널 분할에 필수)
tmux new-session -s work

ship "구현하거나 수정할 내용을 자연어로 설명"
```

**예시**

```bash
ship "로그인 시 이름이 저장 안 되는 버그 수정"
ship "마이페이지 UI를 Figma 디자인대로 구현"
ship "결제 API 연동 및 완료 화면 구현"
```

**자동으로 처리되는 것**

- 🌿 브랜치 생성 (`feat/{slug}-{timestamp}`)
- 🤖 Architect가 필요한 에이전트 자동 선택
- ⚡ Wave A(구현) → Wave B(검증) 병렬 실행
- 💾 Wave 완료마다 중간 커밋/푸시
- 🔍 CI 게이트: tsc → eslint → test → build
- 🔄 게이트 실패 시 자동 수정 (최대 3라운드)
- 📬 PR 자동 생성 (게이트 실패 시 Draft PR)

자세한 내용 → [ship 튜토리얼](https://hwangdahee.github.io/tmux/ship/ship-tutorial.html)

---

## GitHub Pages

이 저장소는 [Jekyll](https://jekyllrb.com/)로 빌드됩니다.

### Pages 활성화

1. GitHub 레포 → **Settings** → **Pages**
2. Source: `Deploy from a branch`
3. Branch: `main` / `/ (root)`
4. Save

몇 분 후 `https://hwangdahee.github.io/tmux` 에서 확인 가능.

### 로컬 미리보기

```bash
# Ruby & Bundler 설치 (처음 한 번)
brew install ruby
gem install bundler

# 의존성 설치
bundle install

# 로컬 서버 실행
bundle exec jekyll serve

# http://localhost:4000/tmux 에서 확인
```

### 새 커맨드 추가 시

`_data/commands.yml`에 항목 추가하면 index 카드 자동 생성:

```yaml
- name: fix
  icon: "⚡"
  status: stable
  status_label: Stable
  desc: "버그 수정에 특화된 커맨드."
  tags: [Debugger, Root Cause]
  links:
    tutorial: fix/fix-tutorial.html
    overview: fix/fix-overview.html
```

---

## 프로젝트 구조

```
tmux/
├── index.html                  # 커맨드 목록 (Liquid 자동 생성)
├── _config.yml                 # Jekyll 설정
├── _data/
│   └── commands.yml            # 커맨드 레지스트리
├── _layouts/
│   └── default.html            # 공통 nav/footer
├── Gemfile
├── README.md
└── ship/
    ├── ship                    # 실행 스크립트
    ├── ship-overview.html      # 개요 카드
    └── ship-tutorial.html      # 설치 및 사용 가이드
```

---

## 문제 해결

**`ship: command not found`**
```bash
export PATH="$HOME/.local/bin:$PATH"
```

**`permission denied: ship`**
```bash
chmod +x ~/.local/bin/ship
```

**tmux 패널이 안 열림**
```bash
echo $TMUX   # 비어있으면 tmux 밖에서 실행 중
tmux new-session -s work
```

**PR이 생성 안 됨**
```bash
gh auth status
cat .agent/ship-*/release_manager.log
```
