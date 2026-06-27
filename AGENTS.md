# AGENTS.md — `~/cluster`

> Flux/Talos GitOps for the mini-cluster. Three N100 mini PCs running
> Proxmox → Talos VMs → Flux-managed apps. Repo:
> `roperscrossroads/cluster` on GitHub.

## What this repo deploys

<!-- generated:apps-tree start -->
```
kubernetes/apps/
├── actions/         # arc-controller, arc-runner-set-rxr-cluster,
│                    #   arc-runner-set-rxr-images,
│                    #   arc-runner-set-rxr-meshsense, forgejo-runner,
│                    #   runner-image-automation — runners spawn in arc-runners
│                    #   ns; ARC controller in arc-systems
├── automation/      # autoloop, dagu, estate-sweep, exposure-check,
│                    #   health-cluster, health-kuma, health-smart, health-zfs,
│                    #   hermes-peer, mcp-reader, memory-loop, nemo-monitor,
│                    #   notes-rag, notes-verifier, ops-data-credentials,
│                    #   researcher — DAGs git-synced from dev/dagu-dags;
│                    #   cluster's workflow engine
├── cert-manager/    # cert-manager
├── cnpg-system/     # operator, operator-crds
├── copilot-peer/    # peer
├── default/         # echo — smoke-test target
├── flux-system/     # flux-instance, flux-operator
├── immich/          # app, pet-tagger
├── inference/       # ollama
├── keda-system/     # keda — classic HelmRepository, NOT OCI (ghcr anon
│                    #   denied on kedacore)
├── kube-system/     # cilium, coredns, metrics-server, reloader, spegel —
│                    #   coredns forwards home.arpa; spegel = registry mirror
├── network/         # cloudflare-dns, cloudflare-tunnel, envoy-gateway,
│                    #   k8s-gateway — envoy-gateway is internal+external;
│                    #   cloudflare-dns = external-dns
├── observability/   # grafana, grafana-operator, kube-prometheus-stack,
│                    #   kube-prometheus-stack-crds
├── openshell/       # agent-sandbox, gateway, litellm-route, sandboxes,
│                    #   secret-sync
└── storage-system/  # democratic-csi-zfs-nfs-1, democratic-csi-zfs-nfs-2,
                     #   democratic-csi-zfs-nvmeof-1,
                     #   democratic-csi-zfs-nvmeof-2, external-snapshotter,
                     #   external-snapshotter-crds, local-path-provisioner —
                     #   zfs-nvmeof-1 is the default StorageClass
```
<!-- generated:apps-tree end -->

## Operational truth

Don't put narrative or runbooks here — they live in `~/notes`:

- [`~/notes/local/infra/mini-cluster/README.md`](../notes/local/infra/mini-cluster/README.md) — phase ladder, status, end-to-end verification matrix
- [`~/notes/local/infra/mini-cluster/apps/`](../notes/local/infra/mini-cluster/apps/) — one doc per namespace
- [`~/notes/local/infra/mini-cluster/storage-tiers.md`](../notes/local/infra/mini-cluster/storage-tiers.md) — picking-a-tier heuristic
- [`~/notes/local/infra/mini-cluster/apps/storage-system.md`](../notes/local/infra/mini-cluster/apps/storage-system.md) — CSI operational view
- [`~/notes/local/infra/mini-cluster/apps/runner-storage.md`](../notes/local/infra/mini-cluster/apps/runner-storage.md) — where CI runners actually write their bytes

## Repo conventions

- **GitOps-only.** Everything that lives on the cluster comes from a
  manifest in this repo. `kubectl apply` against the live cluster is
  for emergency surgery only.
- **App pattern**: `kubernetes/apps/<namespace>/<app>/{ks.yaml,app/{kustomization.yaml,helmrepository.yaml,helmrelease.yaml,secret.sops.yaml}}`. Mirrored from `onedr0p/cluster-template`. New apps: copy the shape from `storage-system/democratic-csi-zfs-nvmeof-1/` or `actions/arc-controller/`.
- **Namespaces.** Each namespace gets its own `kustomization.yaml`
  with `components: [../../components/sops]` and a `resources:` list
  of child `ks.yaml` files. Flux's `cluster-apps` Kustomization
  auto-discovers all namespaces under `./kubernetes/apps`.
- **Atomic commits per app.** One Flux child Kustomization landing per
  commit. Storage and Actions phases shipped as 6 and 7 atomic commits
  respectively. Easier to bisect, easier to roll back, cleaner history.

## Secrets

> Full SOPS/age guide (both this repo and `~/infra-new`, with the
> universal footguns and the per-repo key/path/scope differences):
> [`~/notes/local/infra/sops-age.md`](../notes/local/infra/sops-age.md).

> **IRON RULE — never let a plaintext secret touch disk or shell history.**
> Do NOT hand-roll a secret manifest, `echo`/`cat` a secret into a file, or pass
> a secret as a command argument (it lands in `~/.bash_history` and `ps`). Use
> the `sops-*` just recipes — they pipe `kubectl → sops` so cleartext lives only
> in a kernel pipe:
>
> - **Create:** `just sops-secret <name> <namespace> <repo-relative-dest> --from-file=<key>=<abs-path> [--from-literal=<key>=<non-secret-id>]`
>   — put every *secret* value in a file and use `--from-file` (never `--from-literal` for secrets).
> - **Edit:** `just sops-edit <dest>` · **Verify:** `just sops-verify <dest>` · **Keys:** `just sops-keys <dest>` · **Rotate:** `just sops-refresh <dest>`
>
> This is the muscle-memory path so we stop creating "we need to rotate a leaked
> token" work. Rationale, anti-patterns, and rotation: the sops-age.md guide above.
>
> **Shredding plaintext staging copies is encouraged — but ONLY after end-to-end
> verification** (secret decrypts AND the workload is confirmed running on it).
> Never shred before green: a GitHub App key is shown once, so a premature shred
> forces painful regeneration. Stage under a gitignored `tmp-*` dir, shred when live.

- All secrets are sops-encrypted with **age** (recipient
  `age12rzq0cuqfyh8syej8v26530zhhcag0d9pdsms5sp3c7d4llu7dwq9y2lw5`).
  Private key at `~/cluster/age.key` (gitignored). The same key was
  used by the prior `homelab` repo, so encrypted secrets transfer 1:1
  between them.
- `.sops.yaml` defines two creation rules:
  - `talos/.*\.sops\.ya?ml` → whole-file encryption
  - `(bootstrap|kubernetes)/.*\.sops\.ya?ml` → encrypts only `data` /
    `stringData` fields (so manifests stay diffable)
- **Never commit** `cluster.toml`, `age.key`, `github-deploy.key{,.pub}`,
  `cloudflare-tunnel.json`, `github-push-token.txt`, `kubeconfig`, or
  `talos/clusterconfig/`. All gitignored. The prior `homelab` repo was
  rebuilt because rendered `talos/clusterconfig/*.yaml` files leaked
  raw cluster CA + etcd keys; that class of leak is now structurally
  prevented.

## Flux auth

- GitRepository points at `ssh://git@github.com/roperscrossroads/cluster.git`
- Auth via deploy key (`github-deploy.key{,.pub}`) — public half on
  GitHub repo with **Allow write access** so future image automation
  can push back without a separate PAT.
- The `bootstrap/github-deploy-key.sops.yaml` Secret is rendered by
  `just configure` only when `cluster.toml` has
  `repository.visibility = "private"`. (Note: that flag is named for
  the auth mode — SSH+deploy-key — not for GitHub repo visibility.
  The repo can be public.)

## Two Forgejo instances — runner targets only Dev

The Forgejo k8s runner in `actions/forgejo-runner/` is hardcoded to
`http://172.16.20.16:3000` (gitd backend = Forgejo Dev). The IaC
Forgejo (forged at 172.16.10.17) has Actions disabled at the site
level — workflows there silently never trigger.

If you need IaC-side CI, that's a Forgejo site config change, not a
runner change.

## What runs here vs. on the LXC side

The cluster is the **k8s-native execution surface** of a hybrid estate:

| Concern | Where it lives |
|---|---|
| Container orchestration, k8s CI runners | this repo (cluster) |
| Workflow execution engine (Dagu) | this repo (`automation/`) |
| Storage (CSI / RWX / NFS) | this repo (`storage-system/`) |
| Reverse proxy + Authelia + Caddy | LXC, owned by `~/infra-new` |
| LiteLLM proxy + Postgres + virtual keys | LXC, owned by `~/infra-new` |
| LM Studio (local model serving) | a Windows VM on a separate Proxmox host |
| AFFiNE / Open WebUI / Mattermost (consumer surfaces) | LXC, owned by `~/infra-new` |
| Long-form runbooks | `~/notes/local/infra/` |

The cluster talks to LiteLLM (DNS-resolvable on the home network) for
agent workloads scheduled by Dagu. Cluster pods **can** resolve internal
`home.arpa` and internal service names directly — the CoreDNS Corefile
now has dedicated stub zones forwarding these to the lab resolvers, so
workloads should use FQDNs, not hardcoded IPs.
(The old "use a direct IP" caveat is retired.)

## What's NOT here

- Application data with strong durability requirements (databases for
  AFFiNE, Mattermost, Forgejo, etc.) — those stay on LXC, on
  ZFS-snapshotted storage. The cluster runs workloads, not records of
  truth.
- Authelia / Paperless / etc. — those are LXC services owned by
  `~/infra-new`.

## Common operations

```bash
# Force a Flux reconcile after editing a HelmRelease
flux reconcile kustomization cluster-apps --with-source

# Edit and re-encrypt a secret in-place
sops kubernetes/apps/<...>/secret.sops.yaml

# Render templates from cluster.toml (after changing config)
just configure

# Bootstrap a fresh cluster (rare — only on full rebuilds)
just bootstrap talos
just bootstrap apps
```

## Security posture — supply-chain scanning (in scope, not yet built)

Stated direction (2026-05-21): start adding scanning + detection to
catch supply-chain attacks against the workloads this repo deploys.
Prompted by the 2026-03-24 LiteLLM 1.82.7 / 1.82.8 credential-stealer
incident (on the LXC side; we were unaffected but the close call is a
useful prompt).

Surface area this repo owns:

- **OCI Helm charts** referenced from `kubernetes/apps/*/helm/`
  (cert-manager, Cilium, KEDA, ARC, envoy-gateway, cloudflare
  controllers, democratic-csi, dagu, etc.). Tag-pinned via `interval`
  + `chart` block; no signature verification today.
- **Container images** those charts (and our raw `Deployment`s) pull —
  e.g. forgejo-runner pod, custom MCP / agent images.
- **Cluster bootstrap binaries** pulled by `just bootstrap` and by
  `mise` on the workstation (talos, talhelper, flux, kubectl, helm,
  cilium-cli).
- **Sigstore / cosign signatures** on Flux artifacts themselves (Flux
  publishes signed manifests; we don't verify them today).

Plausible building blocks to evaluate (no commitment yet):

- `flux-operator` supports signature verification via cosign keyless
  on `HelmRelease.spec.chart.spec.verify` — worth enabling per-source.
- Image scanning at admission: kyverno / kyverno-chainsaw policies, or
  trivy-operator running as a cluster scan job.
- `flux image-policy` for upgrade-pressure inside-cluster (alternative
  to Renovate for image tags).
- `osv-scanner` / `trivy` against the repo in CI before Flux even
  picks it up.

Until something is in place, when adding or bumping a chart/image,
**check for recent advisories on it first** and prefer pinning to a
digest (not just a tag) for high-blast-radius components (CSI,
network plugins, anything that runs as cluster-admin).

## When a CLAUDE.md changes

Update `~/.claude/CLAUDE.md` (the user-level project map) if anything
about which repo owns what changes.

## Child DOX Index

No child AGENTS.md yet — this repo is a single DOX scope. Add a child
AGENTS.md (and list it here) when a subtree becomes a durable boundary
with its own rules. `CLAUDE.md` is a symlink to this file (one source).
