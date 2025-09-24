#!/usr/bin/env bash
set -euo pipefail

# =============================
# Configurable variables (can be overridden via env)
# =============================
GO_SCM_DIR="${GO_SCM_DIR:-/Users/akashshrivastava/Workspace/UnifiedRunner/go-scm}"
CORE_DIR="${CORE_DIR:-/Users/akashshrivastava/Workspace/Platform/harness-core}"
RUNNER_CGI_DIR="${RUNNER_CGI_DIR:-/Users/akashshrivastava/.harness-runner/download/cgi/SCM}"

FORK_REMOTE="${FORK_REMOTE:-fork}"
PUSH_BRANCH="${PUSH_BRANCH:-test-runner}"
TARGET_BRANCH="${TARGET_BRANCH:-master}"
FORK_REMOTE_URL="${FORK_REMOTE_URL:-https://github.com/avaakash/go-scm.git}"

REPO_RULE_NAME="${REPO_RULE_NAME:-com_github_drone_go_scm}"
BAZEL_TARGET="${BAZEL_TARGET:-//product/ci/scm:scm}"

DEBUG="${DEBUG:-0}"

# =============================
# Helpers
# =============================
log() { echo "[setup] $*"; }
err() { echo "[setup][ERROR] $*" >&2; }

if [[ "$DEBUG" == "1" ]]; then
  set -x
fi

trap 'err "Failed at line $LINENO"' ERR

# =============================
# 1) Commit & push go-scm changes
# =============================
log "Working in go-scm repo: $GO_SCM_DIR"
cd "$GO_SCM_DIR"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  err "Not a git repository: $GO_SCM_DIR"; exit 1
fi

CUR_BRANCH=$(git rev-parse --abbrev-ref HEAD)
log "Current branch: $CUR_BRANCH"

# Stage all changes
git add -A

if git diff --cached --quiet; then
  log "No staged changes to commit. Using existing HEAD."
else
  log "Amending last commit with staged changes."
  git commit --amend --no-edit
fi

log "Pushing '$PUSH_BRANCH' to '$FORK_REMOTE:$TARGET_BRANCH' (force)"
git push -u "$FORK_REMOTE" "$PUSH_BRANCH:$TARGET_BRANCH" -f

NEW_SHA=$(git rev-parse HEAD)
log "New go-scm commit SHA: $NEW_SHA"

# =============================
# 2) Update WORKSPACE in harness-core
# =============================
log "Updating WORKSPACE in: $CORE_DIR"
cd "$CORE_DIR"

# Pick WORKSPACE.bazel if present, else WORKSPACE
WS_FILE=""
if [[ -f WORKSPACE.bazel ]]; then
  WS_FILE="WORKSPACE.bazel"
elif [[ -f WORKSPACE ]]; then
  WS_FILE="WORKSPACE"
else
  err "WORKSPACE(.bazel) not found in $CORE_DIR"; exit 1
fi

BACKUP_FILE="$WS_FILE.bak.$(date +%s)"
cp "$WS_FILE" "$BACKUP_FILE"
log "Backed up $WS_FILE to $BACKUP_FILE"

log "Updating go_repository('$REPO_RULE_NAME') with commit=$NEW_SHA and remote=$FORK_REMOTE_URL"

# Mac/BSD sed in-place edit. Restrict changes within the named rule block.
# Use '|' as delimiter to avoid conflicts with 'https://'
sed -i '' \
  -e "/name = \"$REPO_RULE_NAME\"/,/)/ s|^[[:space:]]*remote[[:space:]]*=[[:space:]]*\"[^\"]*\"|  remote=\"$FORK_REMOTE_URL\"|" \
  -e "/name = \"$REPO_RULE_NAME\"/,/)/ s|^[[:space:]]*commit[[:space:]]*=[[:space:]]*\"[^\"]*\"|  commit=\"$NEW_SHA\"|" \
  "$WS_FILE"

# Show and verify the updated block for the rule
UPDATED_BLOCK=$(awk "/name = \"$REPO_RULE_NAME\"/{flag=1} flag{print} /\)/{if(flag){exit}}" "$WS_FILE" || true)
echo "$UPDATED_BLOCK"
if ! echo "$UPDATED_BLOCK" | grep -q "$NEW_SHA"; then
  err "Commit SHA was not updated in $WS_FILE (expected $NEW_SHA). Please check formatting of the go_repository block."
fi

# =============================
# 3) Build the CGI binary with Bazel
# =============================
log "Building Bazel target: $BAZEL_TARGET"
bazel build "$BAZEL_TARGET"

BAZEL_BIN=$(bazel info bazel-bin)
ARTIFACT="$BAZEL_BIN/product/ci/scm/scm_/scm"
if [[ ! -f "$ARTIFACT" ]]; then
  err "Built artifact not found at: $ARTIFACT"; exit 1
fi
log "Built artifact: $ARTIFACT"

# =============================
# 4) Deploy to Runner CGI dir
# =============================
TARGET_BINARY="$RUNNER_CGI_DIR/SCM-0.0.2-darwin-arm64"
log "Deploying to: $TARGET_BINARY"
mkdir -p "$RUNNER_CGI_DIR"

rm -f "$TARGET_BINARY"
cp "$ARTIFACT" "$TARGET_BINARY"
chmod +x "$TARGET_BINARY"
ls -l "$TARGET_BINARY" || true

log "Deployment complete."
