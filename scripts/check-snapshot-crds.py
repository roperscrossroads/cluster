#!/usr/bin/env python3
"""Guard: vendored external-snapshotter CRDs must track the snapshot-controller tag.

The VolumeSnapshot and VolumeGroupSnapshot CRDs are vendored verbatim from
upstream into external-snapshotter-crds/app/crds.yaml; the controller image
lives in external-snapshotter/app/controller.yaml. Renovate bumps the image
tag but cannot see the vendored copy, so the two drift.

They did (bead agents-k4io.10): the CRDs stayed at v8.5.0 while the controller
went to v8.7.x, which expects groupsnapshot.storage.k8s.io/v1. Each controller
pod logged "Failed to list v1 volumegroupsnapshots" for ~30 s at start and then
switched the VolumeGroupSnapshot feature off. Plain VolumeSnapshots kept
working, so nothing visible broke, which is why it went unnoticed.

Modes:
  (no args)  check: crds.yaml header version == controller image tag.
             Pure filesystem, stdlib only; pre-commit and CI run this.
  --vendor   re-vendor crds.yaml from upstream at the controller's tag
             (network). Run it after a controller bump, review the diff, and
             commit both together.

Exit 0 if in sync (or vendored), 1 on drift or error.
"""
import re
import sys
import urllib.request
from pathlib import Path

CONTROLLER = Path("kubernetes/apps/storage-system/external-snapshotter/app/controller.yaml")
CRDS = Path("kubernetes/apps/storage-system/external-snapshotter-crds/app/crds.yaml")

# Same order as `cat *.yaml` over upstream's client/config/crd directory, so a
# re-vendor diffs cleanly against earlier copies.
FILES = [
    "groupsnapshot.storage.k8s.io_volumegroupsnapshotclasses.yaml",
    "groupsnapshot.storage.k8s.io_volumegroupsnapshotcontents.yaml",
    "groupsnapshot.storage.k8s.io_volumegroupsnapshots.yaml",
    "snapshot.storage.k8s.io_volumesnapshotclasses.yaml",
    "snapshot.storage.k8s.io_volumesnapshotcontents.yaml",
    "snapshot.storage.k8s.io_volumesnapshots.yaml",
]
RAW = "https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/{ver}/client/config/crd/{f}"

HEADER = """\
# external-snapshotter CRDs — vendored from upstream {ver}
# Source: https://github.com/kubernetes-csi/external-snapshotter/tree/{ver}/client/config/crd
#
# Generated: do not edit. Must match the snapshot-controller image tag in
# ../../external-snapshotter/app/controller.yaml; scripts/check-snapshot-crds.py
# fails pre-commit and CI when they differ. After a controller bump, re-vendor:
#   python3 scripts/check-snapshot-crds.py --vendor
#
"""


def controller_tag(text):
    # image: registry.k8s.io/sig-storage/snapshot-controller:v8.7.1[@sha256:...]
    m = re.search(r"snapshot-controller:(v[0-9][^@\s\"]*)", text)
    return m.group(1) if m else None


def vendored_version(text):
    m = re.search(r"vendored from upstream\s+(\S+)", text)
    return m.group(1) if m else None


def vendor(ver):
    parts = []
    for f in FILES:
        url = RAW.format(ver=ver, f=f)
        with urllib.request.urlopen(url, timeout=30) as r:  # noqa: S310 (fixed https host)
            parts.append(r.read().decode())
    CRDS.write_text(HEADER.format(ver=ver) + "".join(parts))
    print(f"snapshot-crds: vendored {len(FILES)} CRDs from upstream {ver} into {CRDS}")


def main():
    if not CONTROLLER.exists() or not CRDS.exists():
        print(f"snapshot-crds: expected files missing ({CONTROLLER}, {CRDS})", file=sys.stderr)
        return 1

    tag = controller_tag(CONTROLLER.read_text())
    if tag is None:
        print(f"snapshot-crds: no snapshot-controller image tag in {CONTROLLER}", file=sys.stderr)
        return 1

    if sys.argv[1:] == ["--vendor"]:
        vendor(tag)
        return 0
    if sys.argv[1:]:
        print(__doc__, file=sys.stderr)
        return 1

    ver = vendored_version(CRDS.read_text())
    if ver is None:
        print(f"snapshot-crds: no 'vendored from upstream <ver>' header in {CRDS}", file=sys.stderr)
        return 1

    if tag != ver:
        print(
            "snapshot-crds: CRD / snapshot-controller version DRIFT\n"
            f"  controller image tag : {tag}   ({CONTROLLER})\n"
            f"  vendored crds.yaml   : {ver}   ({CRDS})\n\n"
            "The controller was bumped but its CRDs were not re-vendored, so the\n"
            "controller may expect API versions the cluster does not serve (bead\n"
            "agents-k4io.10). Fix:\n"
            "  python3 scripts/check-snapshot-crds.py --vendor\n"
            "then check that no version listed in a CRD's status.storedVersions\n"
            "was dropped (the API server rejects that update), and commit both.",
            file=sys.stderr,
        )
        return 1

    print(f"snapshot-crds: OK — CRDs and controller both at {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
