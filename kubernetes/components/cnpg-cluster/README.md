# CNPG-Cluster Component

Reusable kustomize Component that instantiates a CloudNativePG `Cluster`
plus a `ScheduledBackup`, a `PodMonitor`, and a per-tenant retention
`CronJob` (with its `ServiceAccount`/`Role`/`RoleBinding`), parameterized
via a ConfigMap + replacements.

## What's inside

| File | Resources |
|---|---|
| `cluster.yaml` | `Cluster` (postgresql.cnpg.io/v1) |
| `scheduledbackup.yaml` | `ScheduledBackup` (postgresql.cnpg.io/v1, `method: volumeSnapshot`) |
| `podmonitor.yaml` | `PodMonitor` (monitoring.coreos.com/v1) — replaces the deprecated `spec.monitoring.enablePodMonitor` field on the Cluster CR |
| `retention-rbac.yaml` | `ServiceAccount` + `Role` + `RoleBinding` for the pruner |
| `retention-cronjob.yaml` | `CronJob` — daily prune of stale `Backup` CRs |

Seven distinct objects across five files. `kustomize build` renders all
of them with `PLACEHOLDER_*` strings intact; the consumer substitutes
via `replacements:`.

## Consumer usage

In the consuming app's `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app-namespace>

components:
  - ../../../components/cnpg-cluster

resources:
  # ... other app resources

# If your tenant needs Postgres extensions (e.g. vchord), add a
# strategic-merge patch — see "Adding a vector / non-default extension"
# below for the cluster-extras.yaml pattern.

configMapGenerator:
  - name: cnpg-cluster-config
    literals:
      - APP_NAME=<app>-database
      - RETENTION_NAME=<app>-database-retention
      - DB_NAME=<app>
      - DB_OWNER=<app>
      - INSTANCES=1
      - STORAGE_CLASS=zfs-nvmeof-2
      - STORAGE_SIZE=10Gi
      - IMAGE_NAME=ghcr.io/cloudnative-pg/postgresql:17
      - MEMORY_REQUEST=1Gi
      - MEMORY_LIMIT=2Gi
      - BACKUP_SCHEDULE=0 0 3 * * *      # CNPG cron: leading seconds field
      - SNAPSHOT_CLASS=zfs-nvmeof-2-snapshots
      - BACKUP_RETENTION=30d             # format: Nd (days only)
    options:
      disableNameSuffixHash: true

replacements:
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.APP_NAME }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [metadata.name]
      - select: { kind: ScheduledBackup, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [metadata.name, spec.cluster.name]
      - select: { kind: PodMonitor, name: PLACEHOLDER_APP_NAME }
        fieldPaths:
          - metadata.name
          - metadata.labels.[cnpg.io/cluster]
          - spec.selector.matchLabels.[cnpg.io/cluster]
      - select: { kind: CronJob, name: PLACEHOLDER_RETENTION_NAME }
        fieldPaths:
          - spec.jobTemplate.spec.template.spec.containers.[name=prune].env.[name=CLUSTER_NAME].value
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.RETENTION_NAME }
    targets:
      - select: { kind: ServiceAccount, name: PLACEHOLDER_RETENTION_NAME }
        fieldPaths: [metadata.name]
      - select: { kind: Role, name: PLACEHOLDER_RETENTION_NAME }
        fieldPaths: [metadata.name]
      - select: { kind: RoleBinding, name: PLACEHOLDER_RETENTION_NAME }
        fieldPaths:
          - metadata.name
          - roleRef.name
          - subjects.0.name
      - select: { kind: CronJob, name: PLACEHOLDER_RETENTION_NAME }
        fieldPaths:
          - metadata.name
          - spec.jobTemplate.spec.template.spec.serviceAccountName
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.INSTANCES }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.instances]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.IMAGE_NAME }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.imageName]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.DB_NAME }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.bootstrap.initdb.database]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.DB_OWNER }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.bootstrap.initdb.owner]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.STORAGE_CLASS }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.storage.storageClass]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.STORAGE_SIZE }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.storage.size]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.MEMORY_REQUEST }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.resources.requests.memory]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.MEMORY_LIMIT }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.resources.limits.memory]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.SNAPSHOT_CLASS }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.backup.volumeSnapshot.className]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.BACKUP_SCHEDULE }
    targets:
      - select: { kind: ScheduledBackup, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.schedule]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.BACKUP_RETENTION }
    targets:
      - select: { kind: CronJob, name: PLACEHOLDER_RETENTION_NAME }
        fieldPaths:
          - spec.jobTemplate.spec.template.spec.containers.[name=prune].env.[name=BACKUP_RETENTION].value
```

## Variable surface

| Variable | Purpose | Example |
|---|---|---|
| `APP_NAME` | Base name for Cluster, ScheduledBackup, PodMonitor. CNPG also creates a ServiceAccount with this exact name for the postgres pods, so `RETENTION_NAME` MUST differ from `APP_NAME`. | `immich-database` |
| `RETENTION_NAME` | Name for the pruner CronJob + its ServiceAccount/Role/RoleBinding. **Must differ from `APP_NAME`** to avoid colliding with the CNPG-managed ServiceAccount. | `immich-database-retention` |
| `DB_NAME` | Initial database name | `immich` |
| `DB_OWNER` | App user that owns `DB_NAME` | `immich` |
| `INSTANCES` | Replica count (1 for non-HA) | `1` |
| `STORAGE_CLASS` | StorageClass for the PG data PVC | `zfs-nvmeof-2` |
| `STORAGE_SIZE` | PVC size | `10Gi` |
| `IMAGE_NAME` | Postgres container image | `ghcr.io/cloudnative-pg/postgresql:17` |
| `MEMORY_REQUEST` / `MEMORY_LIMIT` | Per-instance memory ask | `1Gi` / `2Gi` |
| `BACKUP_SCHEDULE` | Cron for ScheduledBackup (CNPG: leading seconds field) | `0 0 3 * * *` |
| `SNAPSHOT_CLASS` | VolumeSnapshotClass for backups | `zfs-nvmeof-2-snapshots` |
| `BACKUP_RETENTION` | Days to retain Backup CRs. **Format: `Nd` (days only)** — the retention CronJob errors on any other suffix. | `30d` |

## Retention

CNPG's `spec.backup.retentionPolicy` is **Barman-only** and is silently
ignored when `method: volumeSnapshot` (see
`internal/webhook/v1/cluster_webhook.go:2640` and
`docs/src/backup.md:158` — "Volume Snapshots: Do not support retention
policies"). That field is therefore intentionally absent from this
Component's `Cluster` CR.

Retention is enforced by `retention-cronjob.yaml`:

- Runs daily at **04:00 UTC** (1 hour after the typical 03:00 backup
  window; schedule is hardcoded — edit the file if your tenant differs).
- Lists `Backup` CRs labelled `cnpg.io/cluster=<APP_NAME>` in the
  tenant's namespace.
- Deletes any whose `metadata.creationTimestamp` is older than
  `BACKUP_RETENTION` days.
- CNPG sets owner references on the VolumeSnapshot it creates per
  Backup → deleting the Backup cascade-deletes the VolumeSnapshot →
  with `deletionPolicy: Delete` on the VolumeSnapshotClass, the
  underlying ZFS snapshot also goes away.

If CNPG eventually ships plugin-based retention (e.g. via the Barman
Cloud Plugin or similar), this CronJob becomes redundant and can be
removed in a Component refresh.

## Adding a vector / non-default extension

Create `cluster-extras.yaml` next to your kustomization.yaml:

```yaml
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: PLACEHOLDER_APP_NAME
spec:
  bootstrap:
    initdb:
      postInitApplicationSQL:
        - CREATE EXTENSION vchord CASCADE;
        - CREATE EXTENSION earthdistance CASCADE;
  postgresql:
    shared_preload_libraries:
      - vchord.so
```

Add it to the consumer kustomization.yaml's `patches:` list (NOT `resources:`
— kustomize forbids two resources with the same id):

```yaml
patches:
  - path: ./cluster-extras.yaml
    target:
      group: postgresql.cnpg.io
      version: v1
      kind: Cluster
      name: PLACEHOLDER_APP_NAME
```

Strategic-merge layers `shared_preload_libraries` and `postInitApplicationSQL`
onto the Component's Cluster. The replacements block above substitutes the
`PLACEHOLDER_APP_NAME` in both the Component's Cluster and (post-patch) the
result.

## Important: snapshot consistency

CNPG quiesces Postgres before triggering `volumeSnapshot` backups,
which is why this Component's backup mode is safe even on
`zfs-nvmeof-*` (block storage where naked snapshots are
crash-consistent only — see `~/notes/local/infra/mini-cluster/immich-design.md`
for the substrate finding). Do not use this Component's backup pattern
for non-CNPG workloads that don't manage their own crash recovery.
