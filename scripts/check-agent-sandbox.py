#!/usr/bin/env python3
"""Guard: the vendored agent-sandbox manifest must match its controller image tag.

kubernetes/apps/openshell/agent-sandbox/app/manifest.yaml is upstream's release
manifest (CRD, RBAC, controller Deployment) vendored verbatim. Renovate bumps
the controller image tag inside it but cannot re-vendor the rest, so the CRD
and RBAC stay at the old release. That happened: the header said v0.5.2 while
the image ran v0.5.6, and Renovate then proposed v1.0.12 (#122), whose
controller needs the v1.0 CRD (v1alpha1 and the conversion webhook removed).

Modes:
  (no args)  check: header version == controller image tag in the same file.
             Pure filesystem, stdlib only; pre-commit and CI run this.
  --vendor   re-vendor the manifest from the release asset for the current
             image tag (network). Run it after a bump, review the diff, and
             read upstream's upgrade notes: a CRD that drops an API version
             needs that version gone from status.storedVersions first.

Exit 0 if in sync (or vendored), 1 on drift or error.
"""
import re
import sys
import urllib.request
from pathlib import Path

MANIFEST = Path("kubernetes/apps/openshell/agent-sandbox/app/manifest.yaml")
URL = "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/{ver}/sandbox.yaml"
HEADER = (
    "# Vendored: kubernetes-sigs/agent-sandbox {ver}\n"
    "# Source: {url}\n"
    "# Generated: do not edit. scripts/check-agent-sandbox.py fails pre-commit and CI\n"
    "# when this version differs from the controller image tag below; after a bump\n"
    "# (Renovate changes only the tag) re-vendor with\n"
    "#   python3 scripts/check-agent-sandbox.py --vendor\n"
)
IMAGE_RE = re.compile(r"image:\s*registry\.k8s\.io/agent-sandbox/agent-sandbox-controller:(v[0-9][^@\s\"]*)")
HEADER_RE = re.compile(r"^# Vendored: kubernetes-sigs/agent-sandbox\s+(v\S+)", re.MULTILINE)


def main():
    if not MANIFEST.exists():
        print(f"agent-sandbox: {MANIFEST} missing", file=sys.stderr)
        return 1
    text = MANIFEST.read_text()
    tags = set(IMAGE_RE.findall(text))
    if len(tags) != 1:
        print(f"agent-sandbox: expected one controller image tag in {MANIFEST}, found {sorted(tags)}",
              file=sys.stderr)
        return 1
    tag = tags.pop()

    if sys.argv[1:] == ["--vendor"]:
        url = URL.format(ver=tag)
        with urllib.request.urlopen(url, timeout=60) as r:  # noqa: S310 (fixed https host)
            body = r.read().decode()
        if set(IMAGE_RE.findall(body)) != {tag}:
            print(f"agent-sandbox: {url} does not deploy controller {tag}", file=sys.stderr)
            return 1
        MANIFEST.write_text(HEADER.format(ver=tag, url=url) + body)
        print(f"agent-sandbox: vendored {url} into {MANIFEST}")
        return 0
    if sys.argv[1:]:
        print(__doc__, file=sys.stderr)
        return 1

    m = HEADER_RE.search(text)
    if not m:
        print(f"agent-sandbox: no '# Vendored: kubernetes-sigs/agent-sandbox <ver>' header in {MANIFEST}",
              file=sys.stderr)
        return 1
    if m.group(1) != tag:
        print(
            "agent-sandbox: manifest / controller version DRIFT\n"
            f"  controller image tag : {tag}\n"
            f"  vendored manifest    : {m.group(1)}   ({MANIFEST})\n\n"
            "The image was bumped without re-vendoring the CRD and RBAC. Fix:\n"
            "  python3 scripts/check-agent-sandbox.py --vendor\n"
            "and check upstream's release notes for CRD version removals (those\n"
            "need status.storedVersions cleaned on the cluster first).",
            file=sys.stderr,
        )
        return 1
    print(f"agent-sandbox: OK — manifest and controller both at {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
