# Node networking as typed documents: the NIC is matched by MAC, static address,
# default route; control planes share the API VIP on it.
apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("{{ .Node.Data.macAddr }}", mac(link.hardware_addr))
{{- if eq .Node.Role "control-plane" }}
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
name: "172.16.21.100"
link: ethSel0
{{- end }}
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
mtu: {{ .Node.Data.mtu }}
addresses:
  - address: "{{ .Node.IP }}/24"
routes:
  - gateway: "172.16.21.1"
