#!/usr/bin/env python3
"""Generate the "Standby apps" GrafanaDashboard manifest.

Usage (from the repo root):
    python3 scripts/dashboards/standby-apps.py

Writes kubernetes/apps/observability/grafana/app/grafanadashboard-standby-apps.yaml.
The manifest goes through Flux post-build substitution, so the output must not
contain a dollar followed by a brace; the script refuses to write it if it does.
"""
import json, pathlib
DS = {"type": "prometheus", "uid": "$datasource"}
REPL = ('max by (namespace, deployment) (kube_deployment_spec_replicas'
  ' * on (namespace, deployment) group_left () label_replace(kube_horizontalpodautoscaler_info{horizontalpodautoscaler=~"keda-hpa-.*"}, "deployment", "$1", "scaletargetref_name", "(.*)")'
  ' * on (namespace, deployment) group_left () label_replace(label_replace(max by (exported_namespace, scaledObject) (keda_scaler_active{scaler="externalPushScaler"}) * 0 + 1, "namespace", "$1", "exported_namespace", "(.*)"), "deployment", "$1", "scaledObject", "(.*)"))')
def inrange(m):
    # counter delta over the dashboard range that also counts series born inside it
    return f'(clamp_min({m} - {m} offset $__range, 0) or {m})'
RT = 'route_name=~"$route"'
panels = []; y = [0]
def row(title):
    panels.append({"type": "row", "title": title, "collapsed": False, "gridPos": {"h": 1, "w": 24, "x": 0, "y": y[0]}, "panels": []}); y[0] += 1
def p(kind, title, targets, x, w, h, desc="", **extra):
    d = {"type": kind, "title": title, "description": desc, "datasource": DS,
         "gridPos": {"h": h, "w": w, "x": x, "y": y[0]},
         "targets": [{"datasource": DS, "refId": chr(65+i), "expr": e, "legendFormat": l, **({"instant": True} if kind in ("stat",) else {})} for i, (e, l) in enumerate(targets)]}
    d.update(extra); panels.append(d)
def stat(title, targets, x, w, desc="", unit="none", mappings=None, thresholds=None, decimals=0):
    p("stat", title, targets, x, w, 5, desc,
      options={"reduceOptions": {"calcs": ["lastNotNull"], "values": False}, "colorMode": "background", "graphMode": "none", "textMode": "value_and_name", "orientation": "horizontal"},
      fieldConfig={"defaults": {"unit": unit, "decimals": decimals, "noValue": "0", "mappings": mappings or [],
        "thresholds": thresholds or {"mode": "absolute", "steps": [{"color": "blue", "value": None}]}}, "overrides": []})
def ts(title, targets, x, w, desc="", unit="short", draw="line", stack=False, extra_defaults=None):
    custom = {"drawStyle": draw, "lineWidth": 1, "fillOpacity": 10 if draw == "line" else 80, "showPoints": "auto", "spanNulls": False,
              "lineInterpolation": "stepAfter" if draw == "line" else "linear", "stacking": {"mode": "normal" if stack else "none"}}
    dflt = {"unit": unit, "custom": custom}; dflt.update(extra_defaults or {})
    p("timeseries", title, targets, x, w, 8, desc,
      options={"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi", "sort": "desc"}},
      fieldConfig={"defaults": dflt, "overrides": []})

row("Standby apps (selected range)")
stat("State now", [(REPL, "{{namespace}}/{{deployment}}")], 0, 6,
     "Replicas of each Deployment scaled by the HTTP add-on (external-push ScaledObjects, found through KEDA operator metrics, which exist since 2026-11-24). 0 = standing by.",
     mappings=[{"type": "value", "options": {"0": {"text": "standby", "color": "blue"}}},
               {"type": "range", "options": {"from": 1, "to": 1000, "result": {"text": "up", "color": "green"}}}])
stat("Wakes", [(f'sum by (namespace, deployment) (count_over_time(({REPL} > 0 and on (namespace, deployment) kube_deployment_spec_replicas offset 1m == 0)[$__range:1m]))', "{{namespace}}/{{deployment}}")], 6, 4,
     "Times replicas went from 0 to more than 0 (one wake, however many requests it held).")
stat("Minutes up", [(f'sum by (namespace, deployment) (count_over_time(({REPL} > 0)[$__range:1m]))', "{{namespace}}/{{deployment}}")], 10, 4,
     "Minutes with at least one replica: what standing by saves is the rest of the range.")
C = lambda o: f'interceptor_cold_start_duration_seconds_count{{outcome="{o}", {RT}}}'
S = f'interceptor_cold_start_duration_seconds_sum{{outcome="ready", {RT}}}'
stat("Avg wait for a wake", [(f'sum by (route_name) ({inrange(S)}) / sum by (route_name) ({inrange(C("ready"))})', "{{route_name}}")], 14, 4,
     "Mean time requests were held while their app started (successful cold starts).", unit="s", decimals=1)
red = {"mode": "absolute", "steps": [{"color": "green", "value": None}, {"color": "red", "value": 1}]}
REJ = f'interceptor_cold_start_rejections_total{{{RT}}}'
stat("Failed wakes", [(f'sum by (route_name) ({inrange(C("timeout"))})', "timeout {{route_name}}"),
                      (f'sum by (route_name) ({inrange(REJ)})', "rejected {{route_name}}")], 18, 6,
     "Requests that got 504 (app not ready within timeouts.readiness) or 503 (more waiting than maxPendingRequests). Alerts: KedaHttpWakeTimedOut, KedaHttpWakeRejected.",
     thresholds=red)
y[0] += 5
ts("Replicas", [(REPL, "{{namespace}}/{{deployment}}")], 0, 12, "Each step up is a wake; each step down is the cooldown ending.")
ts("Requests through the interceptor", [(f'sum by (route_name, code) (rate(interceptor_request_count_total{{{RT}}}[$__rate_interval]))', "{{route_name}} {{code}}")], 12, 12,
   "Per route and status code. Static routes (/healthz) are not counted.", unit="reqps")
y[0] += 8
ts("Wait for a wake (per hour)", [(f'histogram_quantile(0.5, sum by (le, route_name) (increase(interceptor_cold_start_duration_seconds_bucket{{outcome="ready", {RT}}}[1h]))) > 0', "p50 {{route_name}}"),
                                   (f'histogram_quantile(0.95, sum by (le, route_name) (increase(interceptor_cold_start_duration_seconds_bucket{{outcome="ready", {RT}}}[1h]))) > 0', "p95 {{route_name}}")], 0, 8,
   "Cold-start wait over the trailing hour; empty when nothing woke.", unit="s", draw="points")
ts("Request duration p95", [(f'histogram_quantile(0.95, sum by (le, route_name) (rate(interceptor_request_duration_seconds_bucket{{{RT}}}[$__rate_interval]))) > 0', "{{route_name}}")], 8, 8,
   "Includes cold starts, so spikes line up with wakes.", unit="s")
ts("In flight", [(f'sum by (route_name) (interceptor_request_concurrency{{{RT}}})', "{{route_name}}"),
                 ('sum(kube_deployment_status_replicas_ready{namespace="keda-system", deployment="keda-add-ons-http-interceptor"})', "interceptor replicas")], 16, 8,
   "Concurrent requests per route (the scaling metric) and how many interceptors are serving.")
y[0] += 8
row("KEDA core")
stat("Firing alerts", [('count by (alertname) (ALERTS{alertname=~"Keda.*", alertstate="firing"})', "{{alertname}}")], 0, 6,
     "KEDA and add-on alerts firing now.", thresholds=red)
ts("ScaledObject errors", [('sum by (exported_namespace, scaledObject) (increase(keda_scaled_object_errors_total[$__rate_interval]))', "{{exported_namespace}}/{{scaledObject}}")], 6, 9,
   "KEDA failing to evaluate a ScaledObject. Alert: KedaScaledObjectErrors (10 min).", draw="bars")
ts("Scale loop latency", [('max by (exported_namespace, resource) (keda_internal_scale_loop_latency_seconds)', "{{exported_namespace}}/{{resource}}")], 15, 9,
   "How late KEDA's polling loop runs per ScaledObject; growth means the operator is struggling.", unit="s")
y[0] += 8
dash = {"uid": "standby-apps", "title": "Standby apps", "tags": ["keda", "standby"], "editable": True, "schemaVersion": 39,
        "time": {"from": "now-24h", "to": "now"}, "refresh": "1m", "panels": panels,
        "templating": {"list": [
          {"name": "datasource", "type": "datasource", "query": "prometheus", "current": {"text": "prometheus", "value": "prometheus"}, "hide": 0, "label": "Data source"},
          {"name": "route", "type": "query", "datasource": DS, "query": {"query": 'label_values(interceptor_request_count_total{route_name!=""}, route_name)', "refId": "route"},
           "definition": 'label_values(interceptor_request_count_total{route_name!=""}, route_name)', "refresh": 2, "multi": True, "includeAll": True, "allValue": ".*",
           "current": {"text": "All", "value": "$__all"}, "label": "Route"}]}}
out = json.dumps(dash, indent=2)
if "$" + "{" in out:
    raise SystemExit("dollar-brace in the JSON: Flux substitution would eat it")
HEADER = '---\n# Standby apps: scale-to-zero web apps behind the KEDA HTTP add-on, plus\n# KEDA core\'s health. State, wakes, minutes up, wait for a wake and failed\n# wakes per app; traffic per route; ScaledObject errors and firing alerts.\n#\n# Generated by scripts/dashboards/standby-apps.py; edit that and rerun it\n# (python3 scripts/dashboards/standby-apps.py) rather than hand-editing the\n# JSON. Every query was checked against the live Prometheus.\n#\n# This file goes through Flux post-build substitution (the grafana\n# Kustomization substitutes cluster-secrets), so the JSON must not contain a\n# dollar followed by a brace: Grafana variables are written $route,\n# $__range, never with braces.\n#\n# "In range" counts use (x - x offset $__range) or x instead of increase():\n# a failure counter\'s series usually starts with the first failure, and\n# increase() cannot see what a series held at its first sample.\napiVersion: grafana.integreatly.org/v1beta1\nkind: GrafanaDashboard\nmetadata:\n  name: standby-apps\nspec:\n  instanceSelector:\n    matchLabels:\n      dashboards: grafana\n  folder: standby\n  json: |\n'
dest = pathlib.Path(__file__).resolve().parents[2] / "kubernetes/apps/observability/grafana/app/grafanadashboard-standby-apps.yaml"
dest.write_text(HEADER + "".join("    " + line if line.strip() else line for line in (out + "\n").splitlines(True)))
print(f"wrote {dest}")
