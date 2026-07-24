#!/usr/bin/env python3
"""Guard: vendored CloudNativePG CRDs must track the operator chart tag.

The operator chart pins CRD management OFF (crds.create: false); the CRDs are
hand-vendored into operator-crds/app/crds.yaml instead. When the operator
OCIRepository tag is bumped (e.g. by Renovate), crds.yaml MUST be re-vendored
from the SAME chart version. Skip it and the new operator can start against a
CRD set missing types it needs, fail informer cache-sync, never go Ready, and
Helm rolls the upgrade back.

That is exactly what happened 0.28.2 -> 0.29.0 (bead agents-cgp6): the tag was
bumped, crds.yaml was not, so the 1.30.0 operator was missing the new
DatabaseRole CRD and the release sat rolled-back for ~11 days.

This check asserts the crds.yaml header version == the OCIRepository ref.tag.
It deliberately does NOT auto-fix, and the crds.yaml header must NOT carry a
Renovate annotation — a mismatch is the human's cue to run the re-vendor
command documented in the crds.yaml header. Pure filesystem, stdlib only.

Exit 0 if in sync, 1 on drift.
"""
import re
import sys
from pathlib import Path

OCI = Path("kubernetes/apps/cnpg-system/operator/app/ocirepository.yaml")
CRDS = Path("kubernetes/apps/cnpg-system/operator-crds/app/crds.yaml")


def oci_tag(text):
    # spec.ref.tag — the only `tag:` key in this file
    m = re.search(r'^\s+tag:\s*"?([^"\s]+)"?\s*$', text, re.MULTILINE)
    return m.group(1) if m else None


def vendored_version(text):
    # header line: "# ... vendored from chart 0.29.0 (appVersion 1.30.0)"
    m = re.search(r"vendored from chart\s+(\S+)", text)
    return m.group(1) if m else None


def main():
    if not OCI.exists() or not CRDS.exists():
        print(f"cnpg-crds-check: expected files missing ({OCI}, {CRDS})", file=sys.stderr)
        return 1

    tag = oci_tag(OCI.read_text())
    ver = vendored_version(CRDS.read_text())

    if tag is None:
        print(f"cnpg-crds-check: could not find spec.ref.tag in {OCI}", file=sys.stderr)
        return 1
    if ver is None:
        print(f"cnpg-crds-check: could not find 'vendored from chart <ver>' header in {CRDS}", file=sys.stderr)
        return 1

    if tag != ver:
        print(
            "cnpg-crds-check: CRD / operator-chart version DRIFT\n"
            f"  OCIRepository ref.tag : {tag}   ({OCI})\n"
            f"  vendored crds.yaml    : {ver}   ({CRDS})\n\n"
            "The operator chart tag was bumped but the decoupled CRDs were not\n"
            "re-vendored. The new operator can start against a stale CRD set and\n"
            "never become Ready (see bead agents-cgp6). Re-vendor to the new\n"
            f"version using the command in the {CRDS.name} header, then bump its\n"
            "'vendored from chart <ver>' header line to match the tag.",
            file=sys.stderr,
        )
        return 1

    print(f"cnpg-crds-check: OK — CRDs and operator chart both at {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
