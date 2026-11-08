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
