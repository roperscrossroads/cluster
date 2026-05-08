# CLAUDE.md — `~/cluster`

> Flux/Talos GitOps for the mini-cluster. Three N100 mini PCs running
> Proxmox → Talos VMs → Flux-managed apps. Repo:
> `roperscrossroads/cluster` on GitHub.

## What this repo deploys

```
kubernetes/apps/
├── cert-manager/     # ACME issuer for *.ropxr.dev (Cloudflare DNS-01)
├── default/          # echo (smoke test target)
├── flux-system/      # flux-operator + flux-instance (self-managing)
├── kube-system/      # cilium, coredns, metrics-server, reloader, spegel
├── network/          # cloudflare-dns (external-dns), cloudflare-tunnel,
│                     # envoy-gateway (internal + external), k8s-gateway
├── storage-system/   # 4× democratic-csi (zfs-{nfs,nvmeof}-{1,2}) +
│                     # local-path-provisioner. zfs-nvmeof-1 is default.
├── keda-system/      # KEDA 2.19.0 via classic HelmRepository (NOT OCI;
│                     # ghcr.io anonymous DENIED on kedacore org)
└── actions/          # arc-controller (in arc-systems ns), arc-runner-sets
                      # (cluster, meshsense — runners spawn in arc-runners
                      # ns), forgejo-runner (raw Deployment + KEDA SO)
```

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

## What's NOT here

- Application workloads (databases, web apps, etc.) — there are none
  yet. The cluster is currently a fully-functional platform with no
  user apps deployed.
- Authelia / Paperless / etc. — those are LXC services on
  `proxbox`/`proxtwo`, owned by `~/infra-new`.
- Long-form runbooks — those live in `~/notes/local/infra/`.

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

## When a CLAUDE.md changes

Update `~/.claude/CLAUDE.md` (the user-level project map) if anything
about which repo owns what changes.
