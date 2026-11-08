# Talos machine configs (topf)

Machine configs are assembled by [topf](https://postfinance.github.io/topf/)
from `topf.yaml` plus the strategic-merge patches in this directory. topf
replaced talhelper (archived 2026-08) on 2026-11-08; the switch was proven
byte-equivalent (identical rendered configs, empty `apply --dry-run` diff on
every node).

## Layout

- `topf.yaml`: cluster name/endpoint, `talosVersion` + `kubernetesVersion`
  (Renovate-annotated), Image Factory `schematicId`, nodes (`host`, `ip`, `role`,
  per-node `data`: install disk, MAC).
- `secrets.sops.yaml`: the Talos secrets bundle (whole-file sops).
- Patches, merged in this order, lexicographically within each directory:
  - `all/`: every node
  - `control-plane/` / `worker/`: by role
  - `node/<host>/`: one node
- `*.yaml.tpl` patches are Go templates (`.Node.Host`, `.Node.IP`, `.Node.Data.*`,
  `.SchematicID`, `.TalosVersion`, sprig functions, and
  `.Node.RuntimeData.TalosVersion` for version-dependent forms).
- Strategic merge only: use `$patch: delete` (not JSON patches, and not
  talhelper's `$$patch` escape).

## Day 2 (`just talos …`, from the repo root)

| Recipe | What |
|---|---|
| `diff` | `topf apply --dry-run` on every node (exit 2 = pending changes) |
| `render` | write the merged configs to `./rendered/` (gitignored; plaintext PKI) |
| `apply-node <host> [mode]` | apply one node (`auto`, `no-reboot`, `staged`, `try`, `reboot`) |
| `upgrade-node <host>` | Talos upgrade of one node to `talosVersion` (drain, reboot, uncordon) |
| `upgrade-k8s` | Kubernetes to `kubernetesVersion` via `talosctl upgrade-k8s` |
| `talosconfig` | regenerate `talos/talosconfig` (`TALOSCONFIG` points here via mise) |

topf asks before every change; pass `--confirm=false` for non-interactive runs.
Runbook: `~/notes/local/infra/mini-cluster/runbooks/node-reboot.md` §5.

## Talos 1.14 config forms (2026-11)

The patches use the Talos 1.14 multi-document forms (`UnattendedInstallConfig`,
`KubeAPIServerConfig`, `KubeNodeConfig`, `ResolverConfig`, …). Deliberate exceptions and pins:

- **Kubelet stays in `.machine.kubelet`** (deprecated v1alpha1). The 1.14 `KubeletConfig`
  document has no `extraMounts`, and the kubelet still runs as a container, so the
  local-path-provisioner bind mount would vanish. The generated `KubeletConfig` is deleted.
- **`SecurityProfileConfig.workloadIsolation: false`**: the 1.14 default for new configs is
  `true` (sandboxd); upgraded nodes keep the old behaviour, and so do we until chosen.
- **Anonymous auth: Talos default (health endpoints only).** The 1.14 `KubeAuthenticationConfig`
  default allows anonymous requests to `/livez`, `/readyz` and `/healthz` only. Keep it: the
  1.14 kube-apiserver static pod gains startup/liveness/readiness probes, and the kubelet sends
  them unauthenticated. Pinning `anonymous.enabled: false` (as `--anonymous-auth=false` did on
  1.13, which had no probes) makes every probe 401 and the API server crash-loops (2026-11-08).
- **Etcd encryption:** the generated `KubeEtcdEncryptionConfig` lists `secretbox` only;
  the pre-1.14 path also appended an `identity` read fallback. Accepted (2026-11-08): secrets
  have been secretbox-encrypted since bootstrap. Check after the first apply: listing all
  secrets through that node's API server must succeed.

topf renders against each node's *running* version for `apply`/`upgrade`/`diff`, so these
patches only work once a node runs 1.14. The 1.13 → 1.14 hop therefore upgrades nodes with
plain `talosctl upgrade --image` (stored configs stay valid on 1.14), then applies the new
forms with topf. Runbook: `node-reboot.md` §5.
