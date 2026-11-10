# Per-node Kubernetes labels from topf.yaml node data (`nodeLabels`); an empty
# patch is skipped. Talos 1.14 form: KubeNodeConfig `labels`. The v1alpha1
# machine.nodeLabels is refused once a KubeNodeConfig document exists; this
# patch merges key by key with the labels Talos generates (control-plane role
# etc. stay). Talos lists the labels it manages in the node's
# talos.dev/owned-labels annotation. Use a custom prefix: a node may not set
# most kubernetes.io labels on itself.
#
# rxr.lab/ci: "true" marks the nodes CI runners may use (ARC runner sets select
# it). talos-1 is left out on purpose: smallest node, and it carries the API
# server and etcd.
{{- if .Node.Data.nodeLabels }}
apiVersion: v1alpha1
kind: KubeNodeConfig
labels:
  {{- range $k, $v := .Node.Data.nodeLabels }}
  {{ $k }}: {{ $v | quote }}
  {{- end }}
{{- end }}
