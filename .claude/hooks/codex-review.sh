#!/usr/bin/env bash
# Stop hook: hand the current uncommitted diff to Codex for review.
#
# Fires every time Claude finishes a turn, so it is aggressively guarded:
#   1. no uncommitted changes            -> exit
#   2. diff identical to the last review -> exit (no re-reviewing the same state)
#   3. another review already running    -> exit
# Reviews land in .claude/codex-reviews/ as markdown.
#
# Set CODEX_REVIEW_DRY_RUN=1 to exercise the guards without invoking codex.

set -uo pipefail

cat >/dev/null 2>&1 || true   # drain the hook JSON on stdin; we don't need it

command -v codex >/dev/null 2>&1 || exit 0

ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$ROOT" || exit 0

OUT_DIR="$ROOT/.claude/codex-reviews"
LOCK="$OUT_DIR/.lock"
LAST_HASH_FILE="$OUT_DIR/.last-hash"
mkdir -p "$OUT_DIR"

# --- Guard 1: is there anything to review? ------------------------------------
[ -n "$(git status --porcelain 2>/dev/null)" ] || exit 0

# --- Guard 2: have we already reviewed exactly this state? --------------------
# Tracked changes plus the names of untracked files.
HASH=$( { git diff HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null; } | shasum | awk '{print $1}' )
if [ -f "$LAST_HASH_FILE" ] && [ "$HASH" = "$(cat "$LAST_HASH_FILE")" ]; then
    exit 0
fi

# --- Guard 3: don't stack concurrent reviews ----------------------------------
if ! mkdir "$LOCK" 2>/dev/null; then
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$OUT_DIR/review-$STAMP.md"

if [ "${CODEX_REVIEW_DRY_RUN:-0}" = "1" ]; then
    echo "DRY RUN: would review $(git status --porcelain | wc -l | tr -d ' ') changed path(s) -> $OUT"
    echo "$HASH" > "$LAST_HASH_FILE"
    exit 0
fi

# NOTE: `codex exec review` rejects a custom [PROMPT] alongside --uncommitted
# ("the argument '--uncommitted' cannot be used with '[PROMPT]'"), despite what its
# own usage string implies. Verified against codex-cli 0.153.4. The scope flags and
# a custom prompt are mutually exclusive, so we keep the flag -- an unattended hook
# wants its scope enforced, not described in prose -- and accept Codex's default
# review instructions. To swap in custom instructions instead, drop --uncommitted
# and describe the scope in the prompt.
BODY=$(codex exec review --uncommitted 2>&1)
RC=$?

{
    echo "# Codex review — $STAMP"
    echo
    echo '_`codex exec review --uncommitted`, run automatically by the Stop hook._'
    echo
    echo "$BODY"
} > "$OUT"

# A non-zero exit means codex never reviewed anything (bad flags, auth, network).
# Don't record the hash -- otherwise Guard 2 suppresses every future attempt at
# this state -- and don't announce a review that does not exist.
if [ "$RC" -ne 0 ]; then
    printf '{"systemMessage":"Codex review FAILED (exit %s): %s"}\n' "$RC" "${OUT#"$ROOT"/}"
    exit 0
fi

echo "$HASH" > "$LAST_HASH_FILE"

printf '{"systemMessage":"Codex review ready: %s"}\n' "${OUT#"$ROOT"/}"
