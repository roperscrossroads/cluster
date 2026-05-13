# cluster-health DAG — design

**Date:** 2026-05-13
**Status:** Approved for planning
**Repo touched:** `~/cluster` (RBAC + Flux app), `~/dagu-dags` (DAG YAML)

## Goal

A Dagu workflow that peers into the mini-cluster every 8 hours, surfaces
things that need cleanup/fixing/changes, runs an LLM triage pass, commits
the result to `ops-data`, and pushes an ntfy alert only when something is
actually actionable.

This is the in-cluster counterpart to `zfs-health` / `smart-health` /
`kuma-health`. Same mold, same ops-data layout, same chatty-then-silent
ntfy pattern. The structural difference is that it talks to the
Kubernetes API directly via a ServiceAccount instead of SSH'ing anywhere.

## Scope — MVP

Four collectors, each landing one plain-text snapshot under `/data/raw/`:

1. **Workload health** — pods not Ready, CrashLoopBackOff, restart-storms
   (>5 restarts in 24h), ImagePullBackOff, long-pending pods.
2. **Flux drift** — Kustomizations + HelmReleases not Ready, suspended,
   or with `lastAppliedRevision != lastAttemptedRevision`.
3. **Cleanup candidates** — Completed/Failed Jobs > 7d, Evicted pods,
   Released PVs, ReplicaSets with `replicas=0` and age > 7d.
4. **Cert expiry** — cert-manager `Certificate` resources with
   `.status.notAfter` within 14d, `Ready != True`, or `renewalTime`
   already passed.

**Out of scope for MVP** (deferred to future phases / future DAGs):

- Resource pressure (needs `metrics.k8s.io` + per-PVC `df`)
- Event-log clustering (high noise, want a baseline first)
- Helm/upstream upgrade hygiene (different DAG; outbound calls)
- **Auto-deletion of cleanup candidates** (report-only MVP; a future
  `cluster-janitor` DAG can act on the findings once they're trusted)

## Non-goals

- **No mutation of cluster state.** Read-only ClusterRole. No `delete`,
  no `patch`, no `create`.
- **No outbound calls** other than LiteLLM, ntfy, and the ops-data git
  push (all internal).
- **No replacement for Prometheus/Grafana alerting.** This is a once-
  every-8-hours "what changed and what should I look at" digest, not a
  real-time alerter.

## Architecture

```
git_pull  →  collect_workloads ─┐
              collect_flux ─────┤
              collect_cleanup ──┼──→ summarize → package → analyze → write_results_and_push → notify
              collect_certs ────┘
```

Same shape as `zfs-health`:

- Single Dagu workflow, `kubernetes.namespace: automation`.
- Restricted Pod Security: non-root (65534), drop-ALL caps, seccomp
  RuntimeDefault.
- Shared PVC `ops-data-work` (RWX, zfs-nfs) carries `/data/raw/*`,
  `/data/summary.txt`, the cloned `ops-data` working tree, etc.
- `handler_on.failure` pushes a workflow-failed nudge to ntfy with the
  run ID.

### Schedule

`30 */8 * * *` UTC — runs at 00:30, 08:30, 16:30. Offset by :30 to clear
the storage-host neighborhood (zfs at :15, smart at the top of the hour).

### ServiceAccount + RBAC

Lives at `kubernetes/apps/automation/cluster-health/app/rbac.yaml` (new
Flux child Kustomization at `kubernetes/apps/automation/cluster-health/`).

- `ServiceAccount: cluster-health-reader` in `automation` ns
- `ClusterRole: cluster-health-reader` with `get,list` on:
  - core: `pods`, `persistentvolumeclaims`, `persistentvolumes`,
    `services`, `events`, `namespaces`, `nodes`
  - apps: `replicasets`, `deployments`, `statefulsets`, `daemonsets`
  - batch: `jobs`, `cronjobs`
  - `kustomize.toolkit.fluxcd.io`: `kustomizations`
  - `helm.toolkit.fluxcd.io`: `helmreleases`
  - `cert-manager.io`: `certificates`
- `ClusterRoleBinding` tying them together

This SA is used **only** by the cluster-health DAG. The existing default
SA in `automation` (used by other DAGs) is unchanged.

### Image

`bitnami/kubectl:1.31` (or whichever minor matches the cluster) for the
collect/summarize/package steps. `dwdraju/alpine-curl-jq` for analyze
(same as zfs-health). `curlimages/curl` for notify. `alpine/git` for
git_pull and write_results_and_push.

## Collectors

Each collector wraps its command in `continue_on: { failure: true }` and
writes a `COLLECTOR_FAILED reason=<...>` marker to its raw file on
error, so a single missing CRD (e.g. cert-manager not installed) or
transient API blip never tanks the whole run.

Each writes a plain-text snapshot (not JSON) — easier for the awk-based
summary builder and for `git diff` review.

### 1. `collect_workloads` → `/data/raw/workloads.txt`

Two passes, concatenated:

```sh
# pass 1: anything not Running/Succeeded
kubectl get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded \
  -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,\
PHASE:.status.phase,REASON:.status.reason,NODE:.spec.nodeName,\
AGE:.metadata.creationTimestamp

# pass 2: restart-storms (>5 restarts in the last 24h)
kubectl get pods -A -o json | jq -r '
  .items[]
  | select(.status.containerStatuses != null)
  | . as $p
  | $p.status.containerStatuses[]
  | select(.restartCount > 5)
  | "\($p.metadata.namespace)/\($p.metadata.name) container=\(.name) restarts=\(.restartCount) reason=\(.lastState.terminated.reason // "?")"
'
```

### 2. `collect_flux` → `/data/raw/flux.txt`

```sh
kubectl get kustomizations,helmreleases -A -o json | jq -r '
  .items[]
  | . as $r
  | ($r.status.conditions[]? | select(.type=="Ready")) as $ready
  | select(
      $ready.status != "True"
      or ($r.spec.suspend == true)
      or ($r.status.lastAppliedRevision != null
          and $r.status.lastAttemptedRevision != null
          and $r.status.lastAppliedRevision != $r.status.lastAttemptedRevision)
    )
  | "\($r.kind) \($r.metadata.namespace)/\($r.metadata.name) ready=\($ready.status) suspend=\($r.spec.suspend // false) msg=\($ready.message // "-" | .[0:120])"
'
```

### 3. `collect_cleanup` → `/data/raw/cleanup.txt`

Four sub-queries, each emitted under a labeled header:

- `## Jobs (completed >7d OR failed >1d)`:
  `kubectl get jobs -A -o json | jq -r '...select(.status.completionTime older-than 7d or .status.failed > 0 and older-than 1d)...'`
- `## Evicted pods`:
  `kubectl get pods -A --field-selector=status.phase=Failed -o json | jq -r '... select(.status.reason=="Evicted") ...'`
- `## Released PVs`:
  `kubectl get pv -o json | jq -r '... select(.status.phase=="Released") ...'`
- `## Orphan ReplicaSets (replicas=0, age>7d, no current-revision owner)`:
  `kubectl get rs -A -o json | jq -r '... select(.spec.replicas==0 and (older-than 7d) and (.metadata.ownerReferences == null or current-revision check)) ...'`

(Date comparison uses `now - fromdateiso8601` in jq; will be spelled out
fully in the DAG.)

### 4. `collect_certs` → `/data/raw/certs.txt`

```sh
kubectl get certificates.cert-manager.io -A -o json | jq -r '
  .items[]
  | . as $c
  | ($c.status.conditions[]? | select(.type=="Ready")) as $ready
  | (now + 14*86400) as $cutoff
  | select(
      $ready.status != "True"
      or (($c.status.notAfter // "") | fromdateiso8601? // 0) < $cutoff
    )
  | "\($c.metadata.namespace)/\($c.metadata.name) ready=\($ready.status) notAfter=\($c.status.notAfter // "?") renewalTime=\($c.status.renewalTime // "?")"
'
```

If the CRD isn't installed, the command returns non-zero and the
collector falls back to `COLLECTOR_FAILED reason=crd-missing`. That's a
NO_ACTION condition for analyze (cert-manager not present is a state,
not a problem).

## Summarize step — deterministic ground-truth table

Mirrors the zfs-health pattern (env-var script body, awk-based table
builder, bookended around raw snapshots). The pre-computed STATS line
lets the LLM cite numbers without miscounting:

```
=== CLUSTER HEALTH SUMMARY (computed deterministically; ground truth) ===
STATS: workloads=2 issues, flux=1 not-ready, cleanup=14 items, certs=0 expiring

WORKLOADS (2):
  arc-runners/cluster-runner-xyz   ImagePullBackOff   3h    on mini2
  automation/dagu-scheduler-...    CrashLoopBackOff   12r/24h

FLUX (1):
  Kustomization flux-system/cluster-apps  ready=False  msg="prune timeout"

CLEANUP (14):
  jobs       11   (automation: 8, arc-runners: 3)
  evicted     2   (kube-system)
  pv-released 1
  rs-orphan   0

CERTS (0): all healthy, next expiry forge.home.arpa in 47d
=== END CLUSTER HEALTH SUMMARY ===

=== RAW SNAPSHOTS ===
# === workloads ===
... raw.txt contents ...
# === flux ===
...
# === cleanup ===
...
# === certs ===
...
=== END RAW SNAPSHOTS ===

=== CLUSTER HEALTH SUMMARY (repeated for long-context recall) === ...
```

## Package step

Writes to `ops-data` working tree at `cluster/YYYY-MM-DD-HHMM/`:

- `raw.txt` — concatenated raw collector outputs (full forensic trail)
- `summary.txt` — the bookended document fed to the LLM

The `HHMM` suffix is needed because this DAG runs three times a day; the
storage DAGs use just `YYYY-MM-DD` because they only run once. Subdir
layout: `cluster/2026-05-13-0030/`, `cluster/2026-05-13-0830/`, etc.

## Analyze step

Same as zfs-health: POST to LiteLLM `tools` model group with a system
prompt that mandates a two-part reply:

- Line 1: status token — `NO_ACTION` or a short host-prefixed header
- Lines 2-4: 2-4 short sentences (under 600 chars total) citing the
  STATS numbers verbatim and naming specific findings by ns/name

ACTIONABLE conditions for line 1 (escalate from NO_ACTION):

- Any workload issue with age > 1h (transient pod restarts during a
  rollout are expected; sustained issues are not)
- Any Flux resource ready=False for > 30m (transient reconcile failures
  during a push are expected)
- `cleanup.count > 50` — signals upstream automation broken (e.g., a
  TTL controller stopped working, a runner set leaking jobs)
- Any cert with `notAfter < 14d` or `ready != True`
- Any collector returned `COLLECTOR_FAILED` other than
  `reason=crd-missing` for certs

ANALYZE_FAILED fallback is identical to zfs-health (curl-nonzero,
non-json response, empty content → write marker, exit 0, let notify
handle the escalation).

## Write + commit

Identical pattern to zfs-health's `write_results_and_push`:

```
cluster/2026-05-13-0830/
  raw.txt
  summary.txt
  analysis.md         # "# Cluster health 2026-05-13 08:30" header + LLM output
```

Commit message: `cluster($DATE-$TIME): $FIRST_LINE_OF_ANALYSIS`.

NO_ACTION runs still produce commits — the unbroken time series in git
IS the differential. `git log cluster/` becomes the cluster's vital
signs over time.

## Notify

Pushes to **new ntfy topic `cluster`** (separate from `storage` so
storage-host alerts don't drown cluster alerts, and vice-versa).

Chatty-mode-on-first-then-silent pattern (same as zfs-health). Switch
to silent-on-NO_ACTION once the operator has watched a few cycles.

Priority escalations:

- `high` + `warning` tag: cert expiring < 14d, ANALYZE_FAILED, any
  COLLECTOR_FAILED other than crd-missing
- `default` + `gear` tag: normal NO_ACTION / informational

## Files to create

In `~/cluster`:

```
kubernetes/apps/automation/cluster-health/
├── ks.yaml                                    # Flux child Kustomization
└── app/
    ├── kustomization.yaml
    └── rbac.yaml                              # SA + ClusterRole + Binding
```

Plus one line in `kubernetes/apps/automation/kustomization.yaml` to
include the new ks.yaml. Pattern mirrors `automation/zfs-health/`.

In `~/dagu-dags`:

```
dags/cluster-health.yaml                       # the DAG itself
```

No new secrets needed. Reuses:

- `litellm-zfs-key` — the LiteLLM endpoint/key secret (rename to
  `litellm-ops-key` in a future cleanup? out of scope here)
- `ops-data-credentials` — git push credentials
- `internal-ca` ConfigMap — for TLS verification of LiteLLM + git
- `ops-data-work` PVC — shared working dir

## Open questions (resolve during planning, not blocking)

- Should `litellm-zfs-key` be generalized to `litellm-ops-key` before
  this DAG ships, or just reuse the existing name and rename later? Leaning
  toward "reuse, rename in a follow-up commit" — keeps this PR focused.
- Image pin for `bitnami/kubectl` — track cluster version (1.31 today)
  or pin a specific patch? The existing DAGs pin patch versions
  (`alpine/git:2.49.1`), so we'll do the same.
- Should orphan-ReplicaSet detection skip RSs owned by a Deployment
  whose current revision points elsewhere? Yes — that's the only safe
  definition of "orphan." Will spell out the jq predicate in the DAG.

## Future phases (not part of this spec)

- **Phase 2:** Add buckets (4) resource pressure + (7) clustered events.
- **Phase 3:** Add (6) upgrade hygiene as a separate `cluster-upgrades`
  DAG (different shape — outbound calls).
- **Phase 4:** `cluster-janitor` companion DAG that consumes
  cluster-health findings and actually deletes the cleanup candidates
  after operator-set TTLs.
