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

# ── 0. FAIL CLOSED on an unusable range ──────────────────────────────────────
# Every check below degrades to a silent no-op when $RANGE cannot be resolved in
# this clone: gitleaks logs `fatal: Invalid revision range`, reports "0 commits
# scanned" and still EXITS 0; the message and content scans guard on a non-empty
# capture, which an invalid range makes empty. rc stayed 0 and this script
# printed "✓ trust-tier guard clean" having scanned nothing at all.
#
# That is not hypothetical — it happened on 2026-07-25 (bead agents-rtm0) and it
# triggers routinely, because Flux image-automation pushes back with the deploy
# key, so "the remote moved and I have not fetched" is the steady state. A
# secret guard for a PUBLIC mirror must never confuse "could not scan" with
# "nothing to report".
#
# `rev-list --quiet` errors on an INVALID range while succeeding on a
# legitimately EMPTY one, so an empty push still exits 0 without crying wolf.
if [ -n "$RANGE" ]; then
  if ! git -C "$ROOT" rev-list --quiet "$RANGE" -- 2>/dev/null; then
    fail "range '$RANGE' cannot be resolved in this clone — REFUSING to report clean"
    note "  Nothing was scanned. Most likely the remote tip is not in your object"
    note "  store: run 'git fetch' (the remote moves on its own here — image"
    note "  automation and Renovate push back) and retry."
    note "  In CI this means the 'before' commit is unreachable, e.g. after a"
    note "  force-push; scan the whole tree instead by calling scan.sh with no range."
    exit 1
  fi
  COMMITS="$(git -C "$ROOT" rev-list --count "$RANGE" -- 2>/dev/null || echo 0)"
  note "→ range $RANGE resolves to $COMMITS commit(s)"
fi

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

# Say what was actually covered. A bare "clean" is what let a 0-commit scan pass
# for a guard nobody re-reads (agents-rtm0) — make the scope legible in the
# success line itself, so "clean (0 commit(s))" reads as suspicious on sight.
if [ "$rc" -eq 0 ]; then
  if [ -n "$RANGE" ]; then
    note "✓ trust-tier guard clean (${COMMITS:-0} commit(s) in $RANGE)"
  else
    note "✓ trust-tier guard clean (whole tree)"
  fi
fi
exit "$rc"
