set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

# Talos machine configs are assembled by topf from topf.yaml + the patches in
# all/, control-plane/, worker/ and node/<host>/. Nodes are named by host
# (talos-1), not IP. topf asks before changing anything unless --confirm=false
# is passed through args (needed for non-interactive runs, e.g. runbox).

[private]
default:
    just talos -l

[doc('Show pending config changes on every node without applying (exit 2 = changes)')]
[group('talos')]
diff *args:
    topf apply --dry-run {{ args }}

[doc('Render machine configs to ./rendered (gitignored; plaintext PKI)')]
[group('talos')]
render *args:
    topf render --output ./rendered {{ args }}

[doc('List nodes and their live state')]
[group('talos')]
nodes:
    topf nodes

[doc('Apply Talos config to all nodes (shows the diff and asks first)')]
[group('talos')]
apply *args:
    topf apply {{ args }}

[doc('Apply Talos config to one node (mode: auto|no-reboot|reboot|staged|try)')]
[group('talos')]
apply-node node mode='auto' *args:
    topf apply --nodes-filter '^{{ node }}$' --mode '{{ mode }}' {{ args }}

[doc('Write talos/talosconfig (client cert from the secrets bundle)')]
[group('talos')]
talosconfig:
    topf talosconfig > talosconfig

[doc('Reset all nodes back to maintenance mode (DESTRUCTIVE)')]
[group('talos')]
[confirm("This will destroy your cluster and reset all nodes to maintenance mode — continue? [y/N]")]
reset:
    topf reset --full=false --graceful=false --confirm=false

[doc('Reset a single node back to maintenance mode (DESTRUCTIVE)')]
[group('talos')]
[confirm("This will reset the specified node to maintenance mode — continue? [y/N]")]
reset-node node:
    topf reset --nodes-filter '^{{ node }}$' --full=false --graceful=false --confirm=false

[doc('Upgrade Kubernetes to kubernetesVersion in topf.yaml (topf does not manage this)')]
[group('talos')]
upgrade-k8s *args:
    talosctl --nodes "$(yq '[.nodes[] | select(.role == "control-plane")][0].ip' topf.yaml)" \
        upgrade-k8s --to "$(yq '.kubernetesVersion' topf.yaml)" {{ args }}

[doc('Upgrade Talos on one node to talosVersion in topf.yaml (drains, reboots, uncordons)')]
[group('talos')]
upgrade-node node *args:
    topf upgrade --nodes-filter '^{{ node }}$' --drain-timeout 10m {{ args }}
