# trust-tier guard

Keeps genuinely-sensitive material off the **public GitHub mirror** of this
repo. Runs in two places enforcing identical rules (`scan.sh` is shared):

| Where | When | Role |
|---|---|---|
| `scripts/git-hooks/pre-push` | local `git push` | **primary** — fast, catches it before it leaves the machine |
| `.github/workflows/trust-tier-guard.yaml` | `push:[main]` on GitHub | **backstop** — catches a skipped/uninstalled local hook |

Plus `scripts/git-hooks/commit-msg` blocks identifiers in commit *messages* at
commit time (it loads the same `message-denylist.txt`).

## Threat model (the part that matters)

`~/cluster` mirrors to a world-readable GitHub repo, but Flux/manifests
*legitimately* contain internal hostnames and RFC-1918 IPs (registry / LiteLLM
base URLs, LB IP pool, runner targets). So the guard is **not** "scrub all
internal identifiers" — that would be a false-positive storm and break manifests.

**Operator decision (2026-06-14): ACCEPT internal identifiers in tracked
content.** They are non-routable, secretless, and already in the mirror. The
guard therefore protects only three things:

1. **Secrets** — `gitleaks` with `.gitleaks.toml` (Talos PKI, age keys, generic
   secret patterns). SOPS-encrypted files are allowlisted (encryption *is* the
   protection).
2. **Commit messages** — `message-denylist.txt`. History is read by humans
   skimming GitHub; keep identifiers out of subjects/bodies. (Content is exempt.)
3. **Genuinely-external leaks in content** — `content-denylist.txt`. Things that
   are NOT part of the accepted internal corpus (e.g. the work VLAN
   `172.16.80.0/24`, real WAN IPs). Kept deliberately tight.

## Accepted-in-content corpus (NOT flagged)

These appear in manifests by necessity and are explicitly fine in file content:

- `*.home.arpa` (internal DNS, the legacy TLD)
- the cluster's own RFC-1918 ranges: `172.16.20.0/24`, `172.16.21.0/24`
- public registries/domains: `ghcr.io`, `registry.k8s.io`, `public.ecr.aws`,
  `docker.io`, `quay.io`, etc.

**The estate domain is the exception — it is NOT accepted bare.** The repo masks
it as `${SECRET_DOMAIN}` (Flux `postBuild` substitution from `cluster-secrets`).
Internal `.lab` hostnames must be written `lab.${SECRET_DOMAIN}`, never the
literal domain — a bare occurrence is denied (content + message denylists) so the
masking convention can't silently erode. The migration target off `home.arpa` is
`lab.${SECRET_DOMAIN}` (real LE wildcard TLS, home-network-only).

If a new *internal* identifier class starts appearing in content, add it to this
accepted list (documentation), **not** to a denylist.

## Files

- `scan.sh` — the shared scanner. `scan.sh <range>` (e.g. `origin/main..HEAD`)
  or no-arg whole-tree. Exit 1 on any finding.
- `message-denylist.txt` — single source of truth for forbidden **message**
  identifiers (loaded by `scan.sh` *and* the `commit-msg` hook).
- `content-denylist.txt` — external-leak patterns for **content**.

## Install / run

```bash
bash scripts/git-hooks/install.sh        # installs commit-msg + pre-push
scripts/trust-tier/scan.sh origin/main..HEAD   # run manually
```
