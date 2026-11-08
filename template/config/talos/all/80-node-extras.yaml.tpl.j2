# Optional per-node extras from topf.yaml node data (an empty patch is skipped).
{{- if or .Node.Data.encryptDisk .Node.Data.kernelModules }}
machine:
  {{- if .Node.Data.encryptDisk }}
  systemDiskEncryption:
    state:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
    ephemeral:
      provider: luks2
      keys:
        - slot: 0
          tpm: {}
  {{- end }}
  {{- if .Node.Data.kernelModules }}
  kernel:
    modules:
      {{- range .Node.Data.kernelModules }}
      - name: {{ . }}
      {{- end }}
  {{- end }}
{{- end }}
