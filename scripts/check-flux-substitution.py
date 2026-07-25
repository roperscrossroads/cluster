#!/usr/bin/env python3
"""Guard: no unresolvable ${...} in manifests Flux post-build-substitutes.

Flux `postBuild.substituteFrom` runs envsubst over the BUILT manifests. Its
parser owns `${...}` — including shell parameter-expansion forms like
${VAR%suffix}, ${line%=*}, ${line#*=} — and replaces names it cannot resolve
with the EMPTY STRING. `kustomize build` output is unaffected, so the repo
looks correct and only the live object is wrong.

That is bead agents-j44z: commit 2cea480 added substituteFrom to an app purely
to template an ingress hostname, which silently emptied DAYS/NAME/TS in an
unrelated CronJob's prune script. It failed for 51 nights. Worse, emptying the
retention window set the cutoff to "now", turning a pruner into a
delete-every-backup job — it only failed to execute because a second emptied
variable crashed `date` first.

Bare "$VAR" is left alone by envsubst and is the correct way to write shell in
these manifests. `$${...}` is the documented escape for a literal.

A name is considered resolvable if it is:
  - a key of a Secret/ConfigMap named in the Kustomization's substituteFrom
    (keys are readable from *.sops.yaml without decrypting — SOPS encrypts
    values, not keys), or
  - written with an inline default: ${VAR:=fallback}, or
  - escaped as $${VAR}.

Whole-line comments are ignored: the tree legitimately mentions ${VAR} in
prose (e.g. a "you could do this instead" note).

Reachability follows `resources:` and `components:` from each substituted
Kustomization's spec.path, because the file that caused agents-j44z lives in
kubernetes/components/, OUTSIDE any app's spec.path. A checker that only
walked spec.path would have missed it.

Pure filesystem, stdlib only. Exit 0 if clean, 1 on findings.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APPS = REPO / "kubernetes" / "apps"

# ${NAME...} — capture the name and whatever modifier follows it
EXPANSION = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)([^}]*)\}")
# `${` followed by something that cannot begin a variable name — envsubst
# cannot parse it and exits non-zero, failing the whole Kustomization.
UNPARSEABLE = re.compile(r"\$\{(?![A-Za-z_])")
# An uppercase key in a Secret/ConfigMap data block. SOPS metadata keys are
# lowercase (sops, mac, lastmodified, age, ...) so this cannot pick them up.
DATA_KEY = re.compile(r"^\s+([A-Z][A-Z0-9_]*):", re.MULTILINE)
LIST_ITEM = re.compile(r"^\s*-\s+(\S+)\s*$")


def yaml_docs(text):
    """Split on document separators. Good enough for this repo's style."""
    return re.split(r"^---\s*$", text, flags=re.MULTILINE)


def substituted_kustomizations():
    """Yield (ks_path, spec_path, [substituteFrom source names])."""
    for ks in sorted(APPS.glob("*/*/ks.yaml")):
        text = ks.read_text()
        for doc in yaml_docs(text):
            if "substituteFrom" not in doc:
                continue
            m = re.search(r"^\s+path:\s*(\S+)\s*$", doc, re.MULTILINE)
            if not m:
                continue
            spec_path = m.group(1).lstrip("./")
            # names listed under substituteFrom (and any inline substitute: keys)
            block = doc.split("substituteFrom", 1)[1]
            block = re.split(r"^\s{2}\w", block, maxsplit=1, flags=re.MULTILINE)[0]
            sources = re.findall(r"name:\s*(\S+)", block)
            inline = re.findall(r"^\s+([A-Z][A-Z0-9_]*):", doc, re.MULTILINE)
            yield ks, REPO / spec_path, sources, inline


def kustomization_in(directory):
    for name in ("kustomization.yaml", "kustomization.yml"):
        p = directory / name
        if p.is_file():
            return p
    return None


def referenced_paths(kustomization):
    """Local paths listed under resources:/components: in a kustomization."""
    out = []
    key = None
    for raw in kustomization.read_text().splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if re.match(r"^(resources|components):\s*$", stripped):
            key = "follow"
            continue
        if re.match(r"^[A-Za-z]", stripped):  # any other top-level key
            key = None
            continue
        if key == "follow":
            m = LIST_ITEM.match(raw)
            if m and not m.group(1).startswith(("http://", "https://")):
                out.append(m.group(1))
    return out


def reachable_files(start, seen_dirs):
    """Transitively collect manifest files from a kustomize directory."""
    files = set()
    if not start.is_dir() or start in seen_dirs:
        return files
    seen_dirs.add(start)
    kust = kustomization_in(start)
    if kust is None:
        return files
    for ref in referenced_paths(kust):
        target = (start / ref).resolve()
        if target.is_dir():
            files |= reachable_files(target, seen_dirs)
        elif target.is_file():
            files.add(target)
    return files


def resolvable_names(sources, inline):
    """Keys provided by the named Secrets/ConfigMaps, plus inline substitute."""
    names = set(inline)
    for source in sources:
        for candidate in REPO.glob(f"kubernetes/**/{source}.sops.yaml"):
            names |= set(DATA_KEY.findall(candidate.read_text()))
        for candidate in REPO.glob(f"kubernetes/**/{source}.yaml"):
            names |= set(DATA_KEY.findall(candidate.read_text()))
        # ConfigMaps are often named by their file's metadata.name, not filename
        for candidate in REPO.glob("kubernetes/**/*.yaml"):
            text = candidate.read_text(errors="replace")
            if re.search(rf"^\s+name:\s*{re.escape(source)}\s*$", text, re.MULTILINE):
                if re.search(r"^kind:\s*(ConfigMap|Secret)\s*$", text, re.MULTILINE):
                    names |= set(DATA_KEY.findall(text))
    return names


def scan(path, allowed):
    findings = []
    for lineno, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        # An opening `${` whose next character cannot start a variable name is
        # UNPARSEABLE: envsubst exits non-zero and the whole Kustomization
        # fails to apply, rather than quietly substituting an empty string.
        # Checked on every line including comments, because a comment inside a
        # YAML block scalar is string content that Flux still processes. (This
        # very file's explanatory comment tripped it during development.)
        for m in UNPARSEABLE.finditer(raw):
            if m.start() > 0 and raw[m.start() - 1] == "$":
                continue  # $${ — escaped literal
            findings.append((lineno, m.group(0), None, False))

        if raw.lstrip().startswith("#"):
            # A YAML comment is stripped by `kustomize build` and never
            # reaches envsubst, so a resolvable-looking name in one is inert.
            continue
        for m in EXPANSION.finditer(raw):
            if m.start() > 0 and raw[m.start() - 1] == "$":
                continue  # $${VAR} — documented escape for a literal
            name, modifier = m.group(1), m.group(2)
            if ":=" in modifier or ":-" in modifier:
                continue  # inline default makes it resolvable
            if name in allowed:
                # Resolvable name. Any envsubst-supported operator on it is
                # deliberate and works — e.g. ${SECRET_DOMAIN/./-} in the
                # envoy-gateway certs turns example.com into example-com.
                # The hazard is never the operator, it is an UNRESOLVABLE name.
                continue
            findings.append((lineno, m.group(0), name, bool(modifier)))
    return findings


def main():
    if not APPS.is_dir():
        print(f"flux-substitution-check: {APPS} not found", file=sys.stderr)
        return 1

    all_findings = {}
    for ks, spec_path, sources, inline in substituted_kustomizations():
        allowed = resolvable_names(sources, inline)
        for manifest in sorted(reachable_files(spec_path, set())):
            for finding in scan(manifest, allowed):
                rel = manifest.relative_to(REPO)
                all_findings.setdefault((rel, ks.relative_to(REPO)), []).append(finding)

    if not all_findings:
        return 0

    print(
        "flux-substitution-check: found ${...} that Flux post-build substitution\n"
        "will replace with an EMPTY STRING in the rendered object.\n",
        file=sys.stderr,
    )
    for (manifest, ks), findings in sorted(all_findings.items()):
        print(f"  {manifest}   (substituted via {ks})", file=sys.stderr)
        for lineno, text, name, is_shell in findings:
            if name is None:
                why = "UNPARSEABLE by envsubst — fails the whole Kustomization"
            elif is_shell:
                why = "shell parameter expansion — envsubst eats it"
            else:
                why = f"'{name}' is not provided by any substituteFrom source"
            print(f"    line {lineno}: {text}    <- {why}", file=sys.stderr)
    print(
        "\nFix: use bare \"$VAR\" (envsubst leaves it alone) plus cut/sed for string\n"
        "work, or escape a literal as $${VAR}, or add the key to the substituted\n"
        "Secret/ConfigMap, or give it an inline default ${VAR:=fallback}.\n"
        "Background: bead agents-j44z — this class of bug broke a backup-retention\n"
        "CronJob for 51 nights AND briefly made it a delete-everything job.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
