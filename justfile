set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

[group('bootstrap')]
mod? bootstrap 'bootstrap'

[group('kubernetes')]
mod? kube 'kubernetes'

[group('talos')]
mod? talos 'talos'

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

# === template ===

[group('template')]
mod template 'template'

[doc('Render and validate configuration files')]
[group('template')]
configure:
    just template configure

[doc('Initialize configuration files (cluster.toml, age key, deploy key, push token)')]
[group('template')]
init:
    just template init

# === secrets (sops) ===
# Golden rule: a plaintext secret NEVER touches disk or shell history. `sops-secret`
# pipes the rendered manifest straight into sops, so the cleartext exists only in a
# kernel pipe between two processes. Naming mirrors ~/infra-new's `sops-*` group.
# Full guide + rotation + anti-patterns: ~/notes/local/infra/sops-age.md

[doc('Create a sops-encrypted k8s Secret with NO plaintext on disk. Put SECRET values in files and pass --from-file=<key>=<path> (never hits argv/history); --from-literal=<key>=<value> is for NON-secret identifiers ONLY. dest is repo-relative. Ex: just sops-secret my-token my-ns kubernetes/apps/x/app/secret.sops.yaml --from-literal=app_id=123 --from-file=private_key=/abs/path/key.pem')]
[group('sops')]
[script]
sops-secret name namespace dest *args:
    dest_abs="{{ justfile_dir() }}/{{ dest }}"
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    # kubectl renders the Secret to stdout (client-side, no cluster needed); sops
    # encrypts inline. Cleartext lives ONLY in this pipe — never on disk.
    # --filename-override makes sops apply the repo .sops.yaml creation rule for
    # {{ dest }} (age recipient + encrypted_regex), so this stays DRY.
    kubectl create secret generic "{{ name }}" --namespace "{{ namespace }}" {{ args }} \
        --dry-run=client --output yaml \
        | sops --filename-override "{{ dest }}" --encrypt /dev/stdin > "$tmp"
    grep -q '^sops:' "$tmp" || { just log error "sops produced no metadata — refusing to write" dest "{{ dest }}"; exit 1; }
    mkdir -p "$(dirname "$dest_abs")"
    mv "$tmp" "$dest_abs"
    just log info "Wrote sops-encrypted secret (no plaintext touched disk)" dest "{{ dest }}"

[doc('Edit a sops secret in $EDITOR (decrypt → edit → re-encrypt; no plaintext lands in the tree). dest is repo-relative.')]
[group('sops')]
sops-edit dest:
    sops "{{ justfile_dir() }}/{{ dest }}"

[doc('List a sops secret’s keys (names only, never values). dest is repo-relative.')]
[group('sops')]
sops-keys dest:
    sops --decrypt "{{ justfile_dir() }}/{{ dest }}" | yq -r '(.stringData // .data) | keys | .[]'

[doc('Verify a sops secret decrypts cleanly (prints nothing on success). dest is repo-relative.')]
[group('sops')]
sops-verify dest:
    sops --decrypt "{{ justfile_dir() }}/{{ dest }}" > /dev/null && just log info "Decrypts cleanly" dest "{{ dest }}"

[doc('Re-encrypt a sops secret in place after a .sops.yaml recipient change (key rotation). dest is repo-relative.')]
[group('sops')]
sops-refresh dest:
    sops updatekeys "{{ justfile_dir() }}/{{ dest }}"
