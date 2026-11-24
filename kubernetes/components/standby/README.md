# Standby component

Puts a web app behind the KEDA HTTP add-on so it scales to zero when idle and
starts on the first request. Two kustomize Components, filled in by Flux
post-build substitution from `STANDBY_*` variables:

| Component | Objects | Applied by |
|---|---|---|
| `standby` | `InterceptorRoute`, `HTTPRoute`, wake-check `CronJob` | the app's Kustomization |
| `standby-scaling` | `ScaledObject` | a second Kustomization that `dependsOn` the first |

The split is required, not tidiness: a ScaledObject reconciled before its
InterceptorRoute is Ready falls back to a CPU metric, and scale-from-zero
silently never happens. The first Kustomization uses `wait: true`, so the
second starts only once the InterceptorRoute is Ready.

Reference user: `kubernetes/apps/default/echo-standby/`.

## What you write per app

- `app/deployment.yaml`: **no `replicas`** (KEDA owns the count) and a
  readiness probe (the interceptor releases held requests when the pod is
  Ready).
- `app/service.yaml`: named the same as the Deployment (`STANDBY_APP`).
- `app/kustomization.yaml`: those two as `resources`, plus
  `components: [../../../../components/standby]`.
- `scaling/kustomization.yaml`: only
  `components: [../../../../components/standby-scaling]`.
- `ks.yaml`: two Kustomizations, as below.
- Once per namespace: add the namespace to the ReferenceGrant in
  `kubernetes/apps/keda-system/http-add-on/app/referencegrant.yaml`, or the
  HTTPRoute cannot point at the interceptor.

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp
spec:
  dependsOn:
    - name: http-add-on
      namespace: keda-system
  path: ./kubernetes/apps/<ns>/myapp/app
  postBuild:
    substitute:
      STANDBY_APP: myapp            # Deployment, Service and every object's name
      STANDBY_HOSTNAME: myapp-int   # lowercase; host is <this>.<SECRET_DOMAIN>
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  targetNamespace: <ns>
  wait: true                        # required: gates the ScaledObject
  timeout: 5m
  # interval, prune, sourceRef as usual
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: myapp-scaling
spec:
  dependsOn:
    - name: myapp
  path: ./kubernetes/apps/<ns>/myapp/scaling
  postBuild:
    substitute:
      STANDBY_APP: myapp
  targetNamespace: <ns>
  # interval, prune, sourceRef as usual
```

## Variables

| Variable | Default | Used for |
|---|---|---|
| `STANDBY_APP` | required | names; the Service the interceptor forwards to; the Deployment KEDA scales |
| `STANDBY_HOSTNAME` | required | host label, **lowercase** (0.16.0 matches hosts case-sensitively; an uppercase Host gets 404) |
| `STANDBY_PORT` | `80` | Service port |
| `STANDBY_GATEWAY` | `envoy-internal` | `envoy-external` to publish it |
| `STANDBY_HEALTH_PATH` | `/healthz` | static route: answers `standby` at zero without waking the app |
| `STANDBY_WAKE_PATH` | `/` | what the daily wake check requests; must need the app (not the health path) |
| `STANDBY_READINESS_TIMEOUT` | `60s` | how long a request waits for a cold start before 504 |
| `STANDBY_MAX_REPLICAS` | `1` | `standby-scaling` only |
| `STANDBY_COOLDOWN` | `300` | seconds idle before scaling to zero; `standby-scaling` only |

Fixed for every app (change the component if one needs otherwise): 10
concurrent requests per replica, 20 requests held per interceptor during a
cold start (the rest get 503), wake check daily at 09:00 UTC.

## What you get for free

- Kuma/Homepage can poll `STANDBY_HEALTH_PATH`: `standby` while at zero, the
  app's own answer while up, and neither wakes the app nor keeps it awake.
- Alerts on failed wakes (`KedaHttpWakeTimedOut`, `KedaHttpWakeRejected`,
  `KedaHttpRouteServerErrors`) and on ScaledObject errors
  (`KedaScaledObjectErrors`): they match every route by label.
- The daily wake check fails its Job (and raises `KubeJobFailed`) if the app no
  longer starts.
- A row on the "Standby apps" Grafana dashboard.

## Gotchas

- These files and the app's own files are substituted by Flux: anywhere in
  them, comments included, a dollar followed by a brace is either replaced or
  fails the whole Kustomization. Shell in manifests uses bare `$var`. The
  `flux-substitution` pre-commit hook checks this.
- Every request through the interceptor counts toward waking the app, except
  the health path. Point bots and monitors at the health path.
- Not for websockets, long-lived streams or non-HTTP protocols (untested or
  unsupported by the add-on).
