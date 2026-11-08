# Install disk and installer image (Talos >= 1.14: UnattendedInstallConfig; on an
# installed node it only records status, it never reinstalls).
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: "factory.talos.dev/{{ .Node.Data.installer }}/{{ .SchematicID }}:v{{ trimPrefix "v" .TalosVersion }}"
provisioning:
  diskSelector:
    {{- if .Node.Data.installDisk }}
    match: disk.dev_path == "{{ .Node.Data.installDisk }}"
    {{- else }}
    match: disk.serial == "{{ .Node.Data.installDiskSerial }}"
    {{- end }}
  wipe: false
