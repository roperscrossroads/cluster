#!/usr/bin/env bash
# Print stand-in copies of cluster-secrets, one per app namespace, for
# `flate --supply`.
#
# The real cluster-secrets is SOPS-encrypted, so CI cannot read it. Since
# flate 0.8.0 an unreadable substituteFrom value becomes an empty string, and
# charts that require a value (k8s-gateway's `domain`) then fail to render.
# These placeholders give every ${VAR} a harmless value. Supplied objects
# match by namespace and name, and the sops component copies cluster-secrets
# into every namespace, so each namespace needs its own copy.
#
# Usage: flate-stand-in-secrets.sh <path-to-kubernetes/apps>
set -euo pipefail

apps_dir="${1:?usage: $0 <path-to-kubernetes/apps>}"

for dir in "${apps_dir}"/*/; do
  ns="$(basename "${dir}")"
  cat <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: cluster-secrets
  namespace: ${ns}
stringData:
  SECRET_DOMAIN: example.com
  REGISTRY_BASE: registry.example.com
  NTFY_URL: https://ntfy.example.com
EOF
done
