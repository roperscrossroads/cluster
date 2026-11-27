#!/usr/bin/env python3
"""Guard: vendored prometheus-operator CRDs must track the kube-prometheus-stack chart tag.

The chart runs with CRD management off; the ten monitoring.coreos.com CRDs are
vendored into kube-prometheus-stack-crds/app/crds/ and applied by their own
Kustomization (the chart's Kustomization depends on it). Renovate bumps the
chart's OCIRepository tag but cannot see the vendored copies, so a chart bump
lands a newer prometheus-operator on old CRDs. That nearly happened with the
85.4.0 -> 94.1.0 bump (operator v0.90.1 -> v0.95.2; upstream requires CRD
updates at five of those majors), and the copies were already behind the chart
(vendored for 85.1.3).

Every file starts with a header naming the chart version it was vendored for
and the operator release it came from:
  # Vendored for kube-prometheus-stack chart 94.1.0 (prometheus-operator v0.95.2)

Modes:
  (no args)  check: every header's chart version == the OCIRepository tag.
             Pure filesystem, stdlib only; pre-commit and CI run this.
  --vendor   look up the chart's appVersion (`helm show chart`, network) and
             re-vendor all ten CRDs from that prometheus-operator release.
             Run it after a chart bump, review the diff, commit both together.

Exit 0 if in sync (or vendored), 1 on drift or error.
"""
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

OCI = Path("kubernetes/apps/observability/kube-prometheus-stack/app/ocirepository.yaml")
CRD_DIR = Path("kubernetes/apps/observability/kube-prometheus-stack-crds/app/crds")
CHART = "oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack"
RAW = ("https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/"
       "{op}/example/prometheus-operator-crd/monitoring.coreos.com_{plural}.yaml")
PLURALS = [
    "alertmanagerconfigs", "alertmanagers", "podmonitors", "probes",
    "prometheusagents", "prometheuses", "prometheusrules", "scrapeconfigs",
    "servicemonitors", "thanosrulers",
]
HEADER = (
    "# Vendored for kube-prometheus-stack chart {chart} (prometheus-operator {op})\n"
    "# Source: {url}\n"
    "# Generated: do not edit. scripts/check-prometheus-crds.py fails pre-commit and\n"
    "# CI when this differs from the chart tag; re-vendor with\n"
    "#   python3 scripts/check-prometheus-crds.py --vendor\n"
)
HEADER_RE = re.compile(r"Vendored for kube-prometheus-stack chart\s+(\S+)")


def chart_tag():
    m = re.search(r'^\s+tag:\s*"?([^"\s]+)"?\s*$', OCI.read_text(), re.MULTILINE)
    return m.group(1) if m else None


def vendor(tag):
    out = subprocess.run(["helm", "show", "chart", CHART, "--version", tag],
                         check=True, capture_output=True, text=True).stdout
    m = re.search(r"^appVersion:\s*\"?(v?[0-9][^\"\s]*)", out, re.MULTILINE)
    if not m:
        print(f"prometheus-crds: no appVersion in chart {tag}", file=sys.stderr)
        return 1
    op = m.group(1) if m.group(1).startswith("v") else "v" + m.group(1)
    for plural in PLURALS:
        url = RAW.format(op=op, plural=plural)
        with urllib.request.urlopen(url, timeout=30) as r:  # noqa: S310 (fixed https host)
            body = r.read().decode()
        (CRD_DIR / f"crd-{plural}.yaml").write_text(HEADER.format(chart=tag, op=op, url=url) + body)
    print(f"prometheus-crds: vendored {len(PLURALS)} CRDs from prometheus-operator {op} "
          f"(chart {tag}) into {CRD_DIR}")
    return 0


def main():
    if not OCI.exists() or not CRD_DIR.is_dir():
        print(f"prometheus-crds: expected paths missing ({OCI}, {CRD_DIR})", file=sys.stderr)
        return 1
    tag = chart_tag()
    if tag is None:
        print(f"prometheus-crds: no tag in {OCI}", file=sys.stderr)
        return 1

    if sys.argv[1:] == ["--vendor"]:
        return vendor(tag)
    if sys.argv[1:]:
        print(__doc__, file=sys.stderr)
        return 1

    bad = []
    for plural in PLURALS:
        f = CRD_DIR / f"crd-{plural}.yaml"
        m = HEADER_RE.search(f.read_text()) if f.exists() else None
        ver = m.group(1) if m else "missing"
        if ver != tag:
            bad.append(f"  {f.name}: {ver}")
    if bad:
        print(
            "prometheus-crds: CRD / kube-prometheus-stack chart version DRIFT\n"
            f"  chart tag: {tag}   ({OCI})\n" + "\n".join(bad) + "\n\n"
            "The chart was bumped but its CRDs were not re-vendored, so a newer\n"
            "prometheus-operator would run against older CRDs. Fix:\n"
            "  python3 scripts/check-prometheus-crds.py --vendor\n"
            "then check no version in a CRD's status.storedVersions was dropped,\n"
            "and commit the CRDs with the chart bump.",
            file=sys.stderr,
        )
        return 1
    print(f"prometheus-crds: OK — CRDs vendored for chart {tag}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
