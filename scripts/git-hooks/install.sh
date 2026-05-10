#!/bin/bash
# Install repo-local git hooks. Idempotent.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x scripts/git-hooks/commit-msg
ln -sfn ../../scripts/git-hooks/commit-msg .git/hooks/commit-msg
echo "✓ commit-msg hook installed → .git/hooks/commit-msg"
