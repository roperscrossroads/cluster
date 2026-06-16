#!/usr/bin/env python3
"""Generate the `kubernetes/apps/` tree in AGENTS.md (Part 1 — Generate, zero inference).

The filesystem is the source of truth: namespaces are the dirs under
kubernetes/apps/, and each namespace's apps are the child dirs containing a
ks.yaml (a Flux child Kustomization). This script derives that structure and
splices it between the apps-tree sentinels in AGENTS.md, so the tree can never
drift from disk again (it listed 9 of 15 namespaces before this existed).

The ONLY hand-authored input is GLOSS below — a short, stable nuance note per
namespace where the bare app list isn't self-explanatory (mirrors ~/lab's
owns.yaml pattern: derived facts + a thin prose join).

Idempotent. `--check` exits 1 if regeneration would change AGENTS.md (CI gate).
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APPS = os.path.join(ROOT, "kubernetes", "apps")
DOC = os.path.join(ROOT, "AGENTS.md")  # canonical DOX file; CLAUDE.md symlinks to it
# Estate-wide convention (matches ~/lab/scripts/generate.py) so one splice()
# implementation could fill marker blocks in any repo.
MARK_START = "<!-- generated:apps-tree start -->"
MARK_END = "<!-- generated:apps-tree end -->"

# Hand-authored nuance — the only non-derived input. ADD-ONLY: state what the app
# names don't already say (gotchas, defaults, wiring). Never restate the apps.
# Appended after the derived list as "  — <gloss>". Omit a namespace for apps-only.
GLOSS = {
    "actions": "runners spawn in arc-runners ns; ARC controller in arc-systems",
    "automation": "DAGs git-synced from dev/dagu-dags; cluster's workflow engine",
    "keda-system": "classic HelmRepository, NOT OCI (ghcr anon denied on kedacore)",
    "kube-system": "coredns forwards home.arpa; spegel = registry mirror",
    "network": "envoy-gateway is internal+external; cloudflare-dns = external-dns",
    "storage-system": "zfs-nvmeof-1 is the default StorageClass",
    "default": "smoke-test target",
}

WRAP = 54  # max chars per comment chunk


def derive():
    """Return [(namespace, [apps...])] sorted, apps = child dirs with a ks.yaml."""
    out = []
    for ns in sorted(os.listdir(APPS)):
        nsdir = os.path.join(APPS, ns)
        if not os.path.isdir(nsdir):
            continue
        apps = sorted(
            a for a in os.listdir(nsdir)
            if os.path.isfile(os.path.join(nsdir, a, "ks.yaml"))
        )
        out.append((ns, apps))
    return out


def wrap(text, width):
    chunks, line = [], ""
    for word in text.split():
        cand = f"{line} {word}".strip()
        if len(cand) > width and line:
            chunks.append(line)
            line = word
        else:
            line = cand
    if line:
        chunks.append(line)
    return chunks or [""]


def render(tree):
    labels = [f"{'└── ' if i == len(tree) - 1 else '├── '}{ns}/" for i, (ns, _) in enumerate(tree)]
    labelw = max(len(x) for x in labels) + 2
    lines = ["```", "kubernetes/apps/"]
    for i, (ns, apps) in enumerate(tree):
        is_last = i == len(tree) - 1
        desc = ", ".join(apps) if apps else "(no child Kustomizations)"
        if ns in GLOSS:
            desc += f"  — {GLOSS[ns]}"
        chunks = wrap(desc, WRAP)
        gutter = (" " if is_last else "│") + " " * (labelw - 1)
        lines.append(f"{labels[i].ljust(labelw)}# {chunks[0]}")
        for cont in chunks[1:]:
            lines.append(f"{gutter}#   {cont}")
    lines.append("```")
    return "\n".join(lines) + "\n"


def splice(text, block):
    if MARK_START not in text or MARK_END not in text:
        raise SystemExit(f"apps-tree sentinels not found in {DOC}")
    head = text.split(MARK_START)[0]
    tail = text.split(MARK_END)[1]
    return f"{head}{MARK_START}\n{block}{MARK_END}{tail}"


def main():
    check = "--check" in sys.argv
    block = render(derive())
    old = open(DOC).read()
    new = splice(old, block)
    if old == new:
        print(f"apps-tree current ({len(derive())} namespaces)")
        return
    if check:
        print("STALE: AGENTS.md apps-tree would change — run scripts/generate-apps-tree.py", file=sys.stderr)
        sys.exit(1)
    with open(DOC, "w") as f:
        f.write(new)
    print(f"regenerated apps-tree ({len(derive())} namespaces) → AGENTS.md")


if __name__ == "__main__":
    main()
