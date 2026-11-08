# Install disk and installer image (Talos < 1.14 form). On 1.14 this becomes an
# UnattendedInstallConfig document; the two forms are mutually exclusive.
machine:
  install:
    {{- if .Node.Data.installDisk }}
    disk: "{{ .Node.Data.installDisk }}"
    {{- else }}
    diskSelector:
      serial: "{{ .Node.Data.installDiskSerial }}"
    {{- end }}
    image: "factory.talos.dev/{{ .Node.Data.installer }}/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}"
