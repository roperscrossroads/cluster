#!/usr/bin/env bash
# Trust-tier guard for the PUBLIC GitHub mirror. Shared by the local pre-push
# hook (scripts/git-hooks/pre-push) and the GitHub Actions backstop
# (.github/workflows/trust-tier-guard.yaml) so both enforce identical rules.
#
# Three checks (see scripts/trust-tier/README.md for the threat model):
#   1. SECRETS in content        — gitleaks, using .gitleaks.toml
#   2. infra IDs in MESSAGES      — message-denylist.txt over the commit range
#   3. external leaks in CONTENT  — content-denylist.txt over added lines
#
# Usage:
#   scan.sh <git-range>     e.g. scan.sh origin/main..HEAD   (range mode)
#   scan.sh                 no range → whole-tree content + gitleaks, no messages
#
# Exit 0 = clean, 1 = at least one finding (with detail on stderr).
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
DIR="$ROOT/scripts/trust-tier"
RANGE="${1:-}"
rc=0

load_patterns() { grep -vE '^[[:space:]]*(#|$)' "$1" 2>/dev/null || true; }

note()  { printf '%s\n' "$*" >&2; }
fail()  { printf '✗ %s\n' "$*" >&2; rc=1; }

# ── 1. gitleaks (secrets) ────────────────────────────────────────────────────
if command -v gitleaks >/dev/null 2>&1; then GL=(gitleaks); else GL=(mise exec -- gitleaks); fi
note "→ gitleaks (secrets)…"
if [ -n "$RANGE" ]; then
  "${GL[@]}" detect --no-banner --redact --config "$ROOT/.gitleaks.toml" \
      --source "$ROOT" --log-opts="$RANGE" || fail "gitleaks found secret material in $RANGE"
else
  "${GL[@]}" detect --no-banner --redact --config "$ROOT/.gitleaks.toml" \
      --source "$ROOT" || fail "gitleaks found secret material in the worktree"
fi

# ── 2. commit messages vs message-denylist (range mode only) ─────────────────
if [ -n "$RANGE" ]; then
  note "→ commit-message identifier scan ($RANGE)…"
  msgs="$(git -C "$ROOT" log --no-merges --format='%H%n%B' "$RANGE" 2>/dev/null || true)"
  if [ -n "$msgs" ]; then
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      hit="$(printf '%s' "$msgs" | grep -Eo "$pat" | head -1 || true)"
      [ -n "$hit" ] && fail "commit message contains internal identifier '$hit' (pattern: $pat)"
    done < <(load_patterns "$DIR/message-denylist.txt")
  fi
fi

# ── 3. file content vs content-denylist (external leaks) ─────────────────────
note "→ content external-leak scan…"
# Added lines in range mode; whole tracked tree otherwise. Skip SOPS payloads
# and scripts/trust-tier/ itself (its denylists/README document the very
# patterns we scan for — scanning them would be a guaranteed self-match).
excludes=(':(exclude)*.sops.yaml' ':(exclude)*.sops.yml' ':(exclude)*.sops.json' ':(exclude)scripts/trust-tier/*')
if [ -n "$RANGE" ]; then
  added="$(git -C "$ROOT" diff "$RANGE" -- . "${excludes[@]}" \
            | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"
else
  added="$(git -C "$ROOT" grep -hI -nE '.' -- . "${excludes[@]}" 2>/dev/null || true)"
fi
if [ -n "$added" ]; then
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    hit="$(printf '%s' "$added" | grep -Eo "$pat" | head -1 || true)"
    [ -n "$hit" ] && fail "tracked content contains external identifier '$hit' (pattern: $pat)"
  done < <(load_patterns "$DIR/content-denylist.txt")
fi

if [ "$rc" -eq 0 ]; then note "✓ trust-tier guard clean"; fi
exit "$rc"
