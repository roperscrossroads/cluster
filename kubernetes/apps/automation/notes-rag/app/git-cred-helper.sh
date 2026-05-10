#!/bin/sh
# Git credential helper for the notes-rag pipeline.
#
# Reads the Forgejo PAT from a file mounted at /etc/secrets/FORGE_TOKEN
# at credential-request time, so the token never lives in:
#   - the cloned remote URL (which gets persisted to .git/config)
#   - process environment (which leaks via /proc/<pid>/environ + kubectl describe)
#   - the DAG yaml (which is in cluster git history)
#
# git invokes this helper as `<helper> get` when it needs credentials.
# We only respond on `get`, ignoring store/erase per git docs.

case "$1" in
  get)
    echo "username=oauth2"
    echo "password=$(cat /etc/secrets/FORGE_TOKEN)"
    ;;
esac
