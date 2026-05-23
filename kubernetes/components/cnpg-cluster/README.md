# CNPG-Cluster Component

Reusable kustomize Component that instantiates a CloudNativePG `Cluster`
plus a `ScheduledBackup`, parameterized via a ConfigMap + replacements.

## Consumer usage

In the consuming app's `kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app-namespace>

components:
  - ../../../components/cnpg-cluster

resources:
  - ./cluster-extras.yaml      # optional: strategic-merge patch for
                               #           shared_preload_libraries,
                               #           postInitApplicationSQL, etc.
  # ... other app resources

configMapGenerator:
  - name: cnpg-cluster-config
    literals:
      - APP_NAME=<app>-database
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
      - BACKUP_RETENTION=30d
    options:
      disableNameSuffixHash: true

replacements:
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.APP_NAME }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [metadata.name]
      - select: { kind: ScheduledBackup, name: PLACEHOLDER_APP_NAME-snap }
        fieldPaths: [spec.cluster.name]
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
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.BACKUP_RETENTION }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.backup.retentionPolicy]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.SNAPSHOT_CLASS }
    targets:
      - select: { kind: Cluster, name: PLACEHOLDER_APP_NAME }
        fieldPaths: [spec.backup.volumeSnapshot.className]
  - source: { kind: ConfigMap, name: cnpg-cluster-config, fieldPath: data.BACKUP_SCHEDULE }
    targets:
      - select: { kind: ScheduledBackup, name: PLACEHOLDER_APP_NAME-snap }
        fieldPaths: [spec.schedule]
```

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

Add it to the `resources:` list (NOT `patches:` — kustomize strategic-merge
applies via apiVersion+kind+name matching when the same resource is listed
twice). Replacements above will substitute the name placeholder in both files.

## Important: snapshot consistency

CNPG quiesces Postgres before triggering `volumeSnapshot` backups,
which is why this Component's backup mode is safe even on
`zfs-nvmeof-*` (block storage where naked snapshots are
crash-consistent only — see `~/notes/local/infra/mini-cluster/immich-design.md`
for the substrate finding). Do not use this Component's backup pattern
for non-CNPG workloads that don't manage their own crash recovery.
