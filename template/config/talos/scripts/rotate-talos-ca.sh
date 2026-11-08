#!/usr/bin/env bash
# Rotate the Talos API CA (certs.os) and the machine token (trustdinfo.token),
# keeping topf's secrets bundle the source of truth.
#
# Order: prep, generate, accept-new <node> (each node), swap-bundle,
# issue-new <node> (each node), verify, drop-old <node> (each node),
# token-bundle, token-apply <node> (each node), finish, cleanup.
#
# Rollback: before drop-old the old CA is still trusted, so access is never
# lost. accept-new: delete all/90-talos-api-accepted-cas.yaml and apply the
# nodes already done. swap-bundle/issue-new: restore secrets.sops.yaml and the
# patch from the previous commit, render, and apply with talosconfig.dual.
# From drop-old on, fix forward only.
#
# Steps run in order; each one checks its own result and is marked "verified"
# only when every check passes. The next step refuses to start until then.
# Every run appends to rotation/current/log.md.
#
# Secret handling: no secret value is ever printed, passed as an argument or
# written to disk in plaintext. New material goes through pipes into sops;
# the only plaintext files are talosconfigs (client certs, the same kind of file
# as talos/talosconfig, mode 0600, gitignored) and rendered machine configs,
# which live in a tmpfs directory that is shredded on exit.
set -euo pipefail
umask 077

TALOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$TALOS_DIR"
ROT_DIR="$TALOS_DIR/rotation"
RUN="$ROT_DIR/current"
BUNDLE="$TALOS_DIR/secrets.sops.yaml"
PATCH="$TALOS_DIR/all/90-talos-api-accepted-cas.yaml"
CURRENT_TC="$TALOS_DIR/talosconfig"
CTX="kubernetes"
BRANCH="chore/rotate-talos-api-ca"

# ---------- output and log ----------------------------------------------------

FAILED=0
log() { printf '%s\n' "$*" | tee -a "$RUN/log.md"; }
ok() { log "- PASS: $*"; }
bad() { log "- **FAIL: $***"; FAILED=1; }
info() { log "- $*"; }
die() { echo "ERROR: $*" >&2; [[ -d "$RUN" ]] && echo "- **ABORTED: $***" >>"$RUN/log.md"; exit 1; }
header() {
  log ""
  log "## $(date -u +%FT%TZ) \`$*\`"
  log ""
  log "- git: $(git rev-parse --abbrev-ref HEAD)@$(git rev-parse --short HEAD), $(git status --porcelain | wc -l) uncommitted path(s); by ${USER}@$(hostname)"
}
# Keep secret-looking lines out of anything we print: long base64 runs and
# diff lines carrying keys/tokens.
scrub() { grep -vE '[A-Za-z0-9+/=]{40,}' | sed -E 's/((key|token|secret|crt|cert|privateKey|id)"?: ).+/\1<redacted>/I' || true; }

# ---------- state -------------------------------------------------------------

state_get() { grep -E "^$1=" "$RUN/state" 2>/dev/null | tail -1 | cut -d= -f2- || true; }
state_set() { echo "$1=$2" >>"$RUN/state"; log "- state: $1=$2"; }
need() { [[ "$(state_get "$1")" == verified ]] || die "step '$1' is not verified yet (run: just talos rotate status)"; }
finish_step() {
  local key=$1
  if [[ $FAILED -eq 0 ]]; then state_set "$key" verified; log ""; log "**$key: verified.**"
  else state_set "$key" failed; log ""; log "**$key: FAILED; do not continue. See the rollback notes at the top of this script.**"; exit 1; fi
}

# ---------- nodes -------------------------------------------------------------

NODES=()
while read -r h ip; do NODES+=("$h:$ip"); done < <(yq '.nodes[] | .host + " " + .ip' topf.yaml)
node_ip() { local n; for n in "${NODES[@]}"; do [[ ${n%%:*} == "$1" ]] && { echo "${n#*:}"; return; }; done; die "unknown node '$1'"; }
node_names() { local n; for n in "${NODES[@]}"; do echo "${n%%:*}"; done; }

# ---------- certificate helpers (public data only) ----------------------------

# stdin: base64(PEM) as stored in bundles/configs -> one line
b64_fp() { base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2 | tr -d : | cut -c1-16; }
b64_ski() { base64 -d | openssl x509 -noout -ext subjectKeyIdentifier | tail -1 | tr -d ' :'; }
sha12() { sha256sum | cut -c1-12; }
# stdin: base64(PEM) private key -> hash of its public key. Talos labels ED25519 keys
# "ED25519 PRIVATE KEY" (PKCS#8 inside); openssl only reads the standard label.
b64_key_pub() { { base64 -d | sed -E 's/-----(BEGIN|END) ED25519 PRIVATE KEY-----/-----\1 PRIVATE KEY-----/' |
  openssl pkey -pubout 2>/dev/null || echo unreadable; } | sha12; }

bundle_os_crt() { sops -d "$BUNDLE" | yq '.certs.os.crt'; }
old_os_crt() { sops -d "$RUN/secrets.before.sops.yaml" | yq '.certs.os.crt'; }
new_os_crt() { sops -d "$RUN/new.sops.yaml" | yq '.os.crt'; }

# The AKI on a node's apid server certificate = SKI of the CA that issued it.
node_apid_aki() { openssl s_client -connect "$1:50000" </dev/null 2>/dev/null | openssl x509 -noout -ext authorityKeyIdentifier 2>/dev/null | tail -1 | tr -d ' :' || true; }

# Read one field of a node's running v1alpha1 document. Only derived values leave the pipe.
node_field() { # tc ip yq-expr
  talosctl --talosconfig "$1" -n "$2" -e "$2" get mc v1alpha1 -o jsonpath='{.spec}' | yq "select(.machine) | $3"
}
node_ca_fp() { node_field "$1" "$2" '.machine.ca.crt' | b64_fp; }
node_accepted_fps() { node_field "$1" "$2" '(.machine.acceptedCAs // [])[] | .crt' | while read -r c; do echo "$c" | b64_fp; done | paste -sd, -; }
node_token_hash() { node_field "$1" "$2" '.machine.token' | sha12; }

talos_ok() { timeout 30 talosctl --talosconfig "$1" -n "$2" -e "$2" version --short >/dev/null 2>&1; }

# Write a talosconfig whose server trust is the given base64 PEMs concatenated.
tc_with_trust() { # src dst b64pem...
  local src=$1 dst=$2; shift 2
  local pems=""; local c; for c in "$@"; do pems+="$(echo "$c" | base64 -d)"$'\n'; done
  PEMS="$(printf '%s' "$pems" | base64 -w0)" yq ".contexts.$CTX.ca = strenv(PEMS)" "$src" >"$dst"
}

common_health() {
  local nr; nr=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
  [[ $nr -eq ${#NODES[@]} ]] && ok "kubernetes: $nr/${#NODES[@]} nodes Ready" || bad "kubernetes: only $nr/${#NODES[@]} nodes Ready"
  local es; es=$(talosctl --talosconfig "$1" -n "$2" -e "$2" etcd status 2>&1 | awk 'NR>1' || true)
  # With no errors the last column is the storage version; anything else is an error text.
  if [[ -n "$es" ]] && awk '{print $NF}' <<<"$es" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then ok "etcd: member on $2 healthy, no errors"
  else bad "etcd status on $2: $(scrub <<<"$es" | head -c 200)"; fi
}

topf_dry() { # node-filter-regex -> rc (0 = no changes, 2 = changes)
  local rc=0; topf apply --dry-run --nodes-filter "$1" >"$TMP/dry.out" 2>&1 || rc=$?
  echo $rc
}
show_diff() { sed -n '/Config diff/,$p' "$TMP/dry.out" | sed 's/^     //' | scrub | grep -E '^[-+@ ]' | head -60 | sed 's/^/    /' | tee -a "$RUN/log.md"; }
changed_lines() { sed -n '/Config diff/,$p' "$TMP/dry.out" | sed 's/^     //' | grep -E '^[-+][^-+]' || true; }

TMP="$(mktemp -d -p /dev/shm rotate-ca.XXXXXX)"
trap 'find "$TMP" -type f -exec shred -u {} + 2>/dev/null; rmdir "$TMP" 2>/dev/null || true' EXIT

write_patch() { # b64pem -> patch file accepting that CA
  CRT="$1" yq -n '.machine.acceptedCAs = [{"crt": strenv(CRT)}]' >"$PATCH.tmp"
  { echo "# TEMPORARY: Talos API CA rotation in progress (talos/scripts/rotate-talos-ca.sh)."
    echo "# Extra CA trusted by apid besides machine.ca. Public certificate only. Delete in the drop-old step."
    cat "$PATCH.tmp"; } >"$PATCH"; rm -f "$PATCH.tmp"; chmod 644 "$PATCH"
}

# ---------- steps -------------------------------------------------------------

cmd_status() {
  [[ -d "$RUN" ]] || { echo "No rotation in progress (start with: just talos rotate prep)"; return; }
  echo "Run: $(readlink -f "$RUN")"; echo "State:"; sed 's/^/  /' "$RUN/state"
  local oski nski; oski=$(old_os_crt | b64_ski); nski=$( [[ -f "$RUN/new.sops.yaml" ]] && new_os_crt | b64_ski || echo none)
  echo "Old CA SKI: $oski"; echo "New CA SKI: $nski"; echo "Bundle CA SKI: $(bundle_os_crt | b64_ski)"
  local n ip a; for n in $(node_names); do ip=$(node_ip "$n"); a=$(node_apid_aki "$ip")
    printf '  %-8s apid cert issued by: %s\n' "$n" "$([[ $a == "$oski" ]] && echo OLD || { [[ $a == "$nski" ]] && echo NEW || echo "?? $a"; })"
  done
}

cmd_prep() {
  if [[ -e "$RUN" && "$(cat "$RUN/state" 2>/dev/null)" == "prep=failed" ]]; then
    local prev; prev=$(readlink -f "$RUN"); mv "$prev" "$prev.failed"; rm -f "$RUN"
    echo "kept the failed prep run as $(basename "$prev").failed"
  fi
  [[ ! -e "$RUN" ]] || die "a rotation run already exists at $(readlink -f "$RUN"); finish or move it first"
  local id; id="talos-api-ca-$(date -u +%Y%m%d-%H%M)"
  mkdir -p "$ROT_DIR/$id"; ln -sfn "$id" "$RUN"; touch "$RUN/state"
  { echo "# Talos API CA + machine token rotation: $id"; echo
    echo "Log written by \`talos/scripts/rotate-talos-ca.sh\`. Fingerprints and hashes only; no secret values."; } >"$RUN/log.md"
  header prep
  [[ -z "$(git status --porcelain -- .)" ]] && ok "talos/ has no uncommitted changes" || bad "talos/ has uncommitted changes"
  if [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]]; then git switch -q -c "$BRANCH" && info "created branch $BRANCH"; fi
  [[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] && ok "on branch $BRANCH" || bad "not on $BRANCH"
  local oski n ip; oski=$(bundle_os_crt | b64_ski); info "current CA: fp $(bundle_os_crt | b64_fp), SKI $oski, $(bundle_os_crt | base64 -d | openssl x509 -noout -enddate)"
  for n in $(node_names); do ip=$(node_ip "$n")
    talos_ok "$CURRENT_TC" "$ip" && ok "$n: talosconfig works" || bad "$n: talosconfig does not work"
    [[ "$(node_apid_aki "$ip")" == "$oski" ]] && ok "$n: apid cert issued by the bundle CA" || bad "$n: apid cert NOT issued by the bundle CA"
    [[ -z "$(node_accepted_fps "$CURRENT_TC" "$ip")" ]] && ok "$n: no acceptedCAs" || bad "$n: already has acceptedCAs"
    [[ "$(node_ca_fp "$CURRENT_TC" "$ip")" == "$(bundle_os_crt | b64_fp)" ]] && ok "$n: running machine.ca = bundle CA" || bad "$n: running machine.ca differs from bundle"
  done
  local rc; rc=$(topf_dry '.*'); [[ $rc == 0 ]] && ok "topf dry-run: no drift on any node" || bad "topf dry-run rc=$rc (drift; fix before rotating)"
  common_health "$CURRENT_TC" "$(node_ip "$(node_names | head -1)")"
  cp "$BUNDLE" "$RUN/secrets.before.sops.yaml"
  sops -d "$RUN/secrets.before.sops.yaml" | sha12 >/dev/null && ok "backup: bundle copied (still sops-encrypted) and decrypts" || bad "bundle backup does not decrypt"
  sops encrypt --filename-override "$RUN/talosconfig.old.sops.yaml" --input-type yaml --output-type yaml "$CURRENT_TC" >"$RUN/talosconfig.old.sops.yaml"
  # Compare parsed content: sops re-indents YAML, so raw bytes never match.
  [[ "$(sops -d "$RUN/talosconfig.old.sops.yaml" | yq -o json -I0 'sort_keys(..)' | sha12)" == "$(yq -o json -I0 'sort_keys(..)' "$CURRENT_TC" | sha12)" ]] && ok "backup: talosconfig encrypted, round-trips" || bad "talosconfig backup mismatch"
  info "old token hash: $(sops -d "$BUNDLE" | yq '.trustdinfo.token' | sha12)"
  finish_step prep
}

cmd_generate() {
  header generate; need prep
  if [[ -f "$RUN/new.sops.yaml" ]]; then
    [[ "$(state_get generate)" != verified ]] || die "new material already generated and verified"
    info "re-checking the new material staged by an earlier run (not regenerating)"
  else
    talosctl gen secrets -o - 2>/dev/null | yq '{"os": .certs.os, "token": .trustdinfo.token}' |
      sops encrypt --filename-override "$RUN/new.sops.yaml" --input-type yaml --output-type yaml /dev/stdin >"$RUN/new.sops.yaml"
  fi
  local text; text=$(new_os_crt | base64 -d | openssl x509 -noout -text)
  grep -q 'CA:TRUE' <<<"$text" && ok "new CA: basicConstraints CA:TRUE" || bad "new CA is not a CA"
  grep -q 'ED25519' <<<"$text" && ok "new CA: ED25519" || bad "new CA not ED25519"
  [[ "$(new_os_crt | base64 -d | openssl x509 -noout -subject)" == "subject=O = talos" ]] && ok "new CA: subject O=talos" || bad "new CA subject unexpected"
  new_os_crt | base64 -d | openssl x509 -noout -checkend $((9*365*86400)) >/dev/null && ok "new CA: valid > 9 years ($(new_os_crt | base64 -d | openssl x509 -noout -enddate))" || bad "new CA validity too short"
  local kpub cpub; kpub=$(sops -d "$RUN/new.sops.yaml" | yq '.os.key' | b64_key_pub)
  cpub=$(new_os_crt | base64 -d | openssl x509 -noout -pubkey | sha12)
  [[ "$kpub" == "$cpub" ]] && ok "new CA: private key matches certificate" || bad "new CA key/cert mismatch"
  [[ "$(new_os_crt | b64_fp)" != "$(old_os_crt | b64_fp)" ]] && ok "new CA differs from old" || bad "new CA equals old"
  sops -d "$RUN/new.sops.yaml" | yq '.token' | grep -qE '^[a-z0-9]{6}\.[a-z0-9]{16}$' && ok "new token: Talos format" || bad "new token format unexpected"
  [[ "$(sops -d "$RUN/new.sops.yaml" | yq '.token' | sha12)" != "$(sops -d "$BUNDLE" | yq '.trustdinfo.token' | sha12)" ]] && ok "new token differs from old" || bad "new token equals old"
  info "new CA: fp $(new_os_crt | b64_fp), SKI $(new_os_crt | b64_ski); new token hash $(sops -d "$RUN/new.sops.yaml" | yq '.token' | sha12)"
  finish_step generate
}

# Step 2: every node trusts the new CA in addition to the old one.
cmd_accept_new() {
  local n=${1:?node}; local ip; ip=$(node_ip "$n"); header accept-new "$n"; need generate
  [[ "$(state_get "accept-new.$n")" != verified ]] || die "accept-new already verified on $n"
  [[ -f "$PATCH" ]] || { write_patch "$(new_os_crt)"; info "wrote $(basename "$PATCH") (acceptedCAs = new CA); commit it with this step"; }
  local rc; rc=$(topf_dry "^$n\$"); log "- dry-run rc=$rc, diff (secret-looking lines removed):"; show_diff
  local other; other=$(changed_lines | grep -vE '^\+ *(acceptedCAs:|- crt: )' || true)
  [[ $rc == 2 && -z "$other" ]] && ok "diff touches only machine.acceptedCAs" || die "unexpected diff on $n (rc=$rc); nothing applied"
  topf apply --nodes-filter "^$n\$" --mode no-reboot --confirm=false 2>&1 | scrub | grep -E 'level=|rror' | tee -a "$RUN/log.md"
  state_set "accept-new.$n" applied
  check_accept_new "$n"
}
check_accept_new() {
  local n=$1 ip; ip=$(node_ip "$n"); FAILED=0; log "- checks for accept-new on $n:"
  [[ "$(node_accepted_fps "$CURRENT_TC" "$ip")" == "$(new_os_crt | b64_fp)" ]] && ok "$n: acceptedCAs = [new CA]" || bad "$n: acceptedCAs = [$(node_accepted_fps "$CURRENT_TC" "$ip")]"
  [[ "$(node_ca_fp "$CURRENT_TC" "$ip")" == "$(old_os_crt | b64_fp)" ]] && ok "$n: machine.ca still the old CA" || bad "$n: machine.ca changed unexpectedly"
  [[ "$(node_apid_aki "$ip")" == "$(old_os_crt | b64_ski)" ]] && ok "$n: apid cert still from old CA" || bad "$n: apid cert issuer changed"
  talos_ok "$CURRENT_TC" "$ip" && ok "$n: current talosconfig works" || bad "$n: current talosconfig broken"
  common_health "$CURRENT_TC" "$ip"
  finish_step "accept-new.$n"
}

# Step 3a: the bundle issues from the new CA; the patch keeps the old CA trusted.
cmd_swap_bundle() {
  header swap-bundle; local n; for n in $(node_names); do need "accept-new.$n"; done
  [[ "$(state_get swap-bundle)" != verified ]] || die "already done"
  local before; before=$(sops -d "$BUNDLE" | yq 'del(.certs.os)' | sha12)
  yq '.certs.os = load("/dev/fd/3").os' <(sops -d "$BUNDLE") 3< <(sops -d "$RUN/new.sops.yaml") |
    sops encrypt --filename-override "$BUNDLE" --input-type yaml --output-type yaml /dev/stdin >"$TMP/bundle.enc"
  sops -d --filename-override "$BUNDLE" "$TMP/bundle.enc" >/dev/null && cp "$TMP/bundle.enc" "$BUNDLE" || die "new bundle does not decrypt; bundle untouched"
  [[ "$(bundle_os_crt | b64_fp)" == "$(new_os_crt | b64_fp)" ]] && ok "bundle certs.os = new CA" || bad "bundle certs.os not the new CA"
  [[ "$(sops -d "$BUNDLE" | yq 'del(.certs.os)' | sha12)" == "$before" ]] && ok "every other bundle field unchanged" || bad "other bundle fields changed"
  [[ "$(sops -d "$BUNDLE" | yq '.certs.os.key' | b64_key_pub)" == "$(bundle_os_crt | base64 -d | openssl x509 -noout -pubkey | sha12)" ]] && ok "bundle key matches bundle cert" || bad "bundle key/cert mismatch"
  write_patch "$(old_os_crt)"; info "rewrote $(basename "$PATCH") (acceptedCAs = old CA); commit bundle + patch with this step"
  topf talosconfig >"$RUN/talosconfig.new"
  tc_with_trust "$RUN/talosconfig.new" "$RUN/talosconfig.dual" "$(new_os_crt)" "$(old_os_crt)"
  tc_with_trust "$CURRENT_TC" "$RUN/talosconfig.oldcert-dual" "$(new_os_crt)" "$(old_os_crt)"
  info "wrote talosconfig.new (new client cert, trusts new CA), talosconfig.dual (new client cert, trusts both), talosconfig.oldcert-dual (old client cert, trusts both; used to prove the old CA is dead)"
  for n in $(node_names); do local ip; ip=$(node_ip "$n")
    talos_ok "$RUN/talosconfig.dual" "$ip" && ok "$n: accepts a client cert from the NEW CA" || bad "$n: rejects the new-CA client cert"
    talos_ok "$CURRENT_TC" "$ip" && ok "$n: old talosconfig still works" || bad "$n: old talosconfig broken"
  done
  finish_step swap-bundle
}

# Step 3b: per node, make the new CA the issuer (rendered from the bundle, applied
# with the dual talosconfig because topf now trusts only the new CA).
cmd_issue_new() {
  local n=${1:?node}; local ip; ip=$(node_ip "$n"); header issue-new "$n"; need swap-bundle
  [[ "$(state_get "issue-new.$n")" != verified ]] || die "issue-new already verified on $n"
  local tv rv; tv=$(yq '.talosVersion' topf.yaml); rv=$(talosctl --talosconfig "$RUN/talosconfig.dual" -n "$ip" -e "$ip" version --short 2>/dev/null | awk '/Tag:/{t=$2} END{print t}')
  [[ "$tv" == "$rv" ]] && ok "$n runs $rv = topf.yaml talosVersion" || die "$n runs $rv but topf.yaml says $tv; offline render would use the wrong contract"
  topf render --nodes-filter "^$n\$" -o "$TMP/render" >/dev/null 2>&1 || die "topf render failed"
  local f="$TMP/render/$n.yaml"; [[ -s "$f" ]] || die "no rendered config for $n"
  [[ "$(yq 'select(.machine) | .machine.ca.crt' "$f" | b64_fp)" == "$(new_os_crt | b64_fp)" ]] && ok "rendered machine.ca = new CA" || die "rendered machine.ca is not the new CA"
  [[ "$(yq 'select(.machine) | (.machine.acceptedCAs // [])[] | .crt' "$f" | b64_fp)" == "$(old_os_crt | b64_fp)" ]] && ok "rendered acceptedCAs = [old CA]" || die "rendered acceptedCAs wrong"
  [[ "$(yq 'select(.machine) | .machine.token' "$f" | sha12)" == "$(node_token_hash "$RUN/talosconfig.dual" "$ip")" ]] && ok "rendered token = running token (unchanged in this step)" || die "rendered token differs"
  talosctl --talosconfig "$RUN/talosconfig.dual" -n "$ip" -e "$ip" apply-config --dry-run --mode no-reboot --file "$f" >"$TMP/dry.out" 2>&1 || die "apply-config dry-run failed: $(scrub <"$TMP/dry.out" | tail -3)"
  log "- dry-run diff (secret-looking lines removed):"; show_diff
  local other; other=$(changed_lines | grep -vE '^[-+] *(ca:|crt: |key: |acceptedCAs:|- crt: )|redacted|\*\*\*' || true)
  [[ -z "$other" ]] && ok "diff touches only machine.ca and machine.acceptedCAs" || die "unexpected diff lines on $n; nothing applied: $(scrub <<<"$other" | head -5)"
  talosctl --talosconfig "$RUN/talosconfig.dual" -n "$ip" -e "$ip" apply-config --mode no-reboot --file "$f" 2>&1 | scrub | tee -a "$RUN/log.md"
  state_set "issue-new.$n" applied
  local i; for i in $(seq 1 12); do [[ "$(node_apid_aki "$ip")" == "$(new_os_crt | b64_ski)" ]] && break; sleep 5; done
  check_issue_new "$n"
}
check_issue_new() {
  local n=$1 ip; ip=$(node_ip "$n"); FAILED=0; log "- checks for issue-new on $n:"
  [[ "$(node_apid_aki "$ip")" == "$(new_os_crt | b64_ski)" ]] && ok "$n: apid cert now issued by the NEW CA" || bad "$n: apid cert not from the new CA"
  [[ "$(node_ca_fp "$RUN/talosconfig.dual" "$ip")" == "$(new_os_crt | b64_fp)" ]] && ok "$n: machine.ca = new CA" || bad "$n: machine.ca not new"
  [[ "$(node_accepted_fps "$RUN/talosconfig.dual" "$ip")" == "$(old_os_crt | b64_fp)" ]] && ok "$n: acceptedCAs = [old CA]" || bad "$n: acceptedCAs wrong"
  talos_ok "$RUN/talosconfig.new" "$ip" && ok "$n: talosconfig.new (new CA only) works" || bad "$n: talosconfig.new fails"
  talos_ok "$RUN/talosconfig.dual" "$ip" && ok "$n: talosconfig.dual works" || bad "$n: talosconfig.dual fails"
  common_health "$RUN/talosconfig.dual" "$ip"
  finish_step "issue-new.$n"
}

# Step 4: everything matches the repo; install the new talosconfig.
cmd_verify() {
  header verify; local n ip; for n in $(node_names); do need "issue-new.$n"; done
  for n in $(node_names); do ip=$(node_ip "$n")
    talos_ok "$RUN/talosconfig.new" "$ip" && ok "$n: talosconfig.new works" || bad "$n: talosconfig.new fails"
    [[ "$(node_apid_aki "$ip")" == "$(new_os_crt | b64_ski)" ]] && ok "$n: apid cert from new CA" || bad "$n: apid cert not from new CA"
  done
  local rc; rc=$(topf_dry '.*'); [[ $rc == 0 ]] && ok "topf dry-run: live configs match the repo on every node" || bad "topf dry-run rc=$rc (drift)"
  common_health "$RUN/talosconfig.new" "$(node_ip "$(node_names | head -1)")"
  if [[ $FAILED -eq 0 ]]; then cp "$RUN/talosconfig.new" "$CURRENT_TC"; ok "installed talosconfig.new as talos/talosconfig (old one is in talosconfig.old.sops.yaml)"; fi
  finish_step verify
}

# Step 5: stop trusting the old (leaked) CA.
cmd_drop_old() {
  local n=${1:?node}; local ip; ip=$(node_ip "$n"); header drop-old "$n"; need verify
  [[ "$(state_get "drop-old.$n")" != verified ]] || die "drop-old already verified on $n"
  if [[ -f "$PATCH" ]]; then rm "$PATCH"; info "removed $(basename "$PATCH"); commit the removal with this step"; fi
  local rc; rc=$(topf_dry "^$n\$"); log "- dry-run rc=$rc, diff:"; show_diff
  local other; other=$(changed_lines | grep -vE '^- *(acceptedCAs:|- crt: )' || true)
  [[ $rc == 2 && -z "$other" ]] && ok "diff only removes machine.acceptedCAs" || die "unexpected diff on $n (rc=$rc); nothing applied"
  topf apply --nodes-filter "^$n\$" --mode no-reboot --confirm=false 2>&1 | scrub | grep -E 'level=|rror' | tee -a "$RUN/log.md"
  state_set "drop-old.$n" applied
  sleep 5; check_drop_old "$n"
}
check_drop_old() {
  local n=$1 ip; ip=$(node_ip "$n"); FAILED=0; log "- checks for drop-old on $n:"
  [[ -z "$(node_accepted_fps "$CURRENT_TC" "$ip")" ]] && ok "$n: acceptedCAs empty" || bad "$n: acceptedCAs still set"
  [[ "$(node_ca_fp "$CURRENT_TC" "$ip")" == "$(new_os_crt | b64_fp)" ]] && ok "$n: machine.ca = new CA" || bad "$n: machine.ca not new"
  talos_ok "$CURRENT_TC" "$ip" && ok "$n: talosconfig works" || bad "$n: talosconfig fails"
  if talos_ok "$RUN/talosconfig.oldcert-dual" "$ip"; then bad "$n: a client cert from the OLD CA is still accepted"
  else ok "$n: a client cert from the OLD CA is rejected (the leaked key no longer opens this node)"; fi
  common_health "$CURRENT_TC" "$ip"
  finish_step "drop-old.$n"
}

# Step 6: new machine token (bundle once, then per node).
cmd_token_bundle() {
  header token-bundle; local n; for n in $(node_names); do need "drop-old.$n"; done
  [[ "$(state_get token-bundle)" != verified ]] || die "already done"
  local before; before=$(sops -d "$BUNDLE" | yq 'del(.trustdinfo.token)' | sha12)
  yq '.trustdinfo.token = load("/dev/fd/3").token' <(sops -d "$BUNDLE") 3< <(sops -d "$RUN/new.sops.yaml") |
    sops encrypt --filename-override "$BUNDLE" --input-type yaml --output-type yaml /dev/stdin >"$TMP/bundle.enc"
  sops -d --filename-override "$BUNDLE" "$TMP/bundle.enc" >/dev/null && cp "$TMP/bundle.enc" "$BUNDLE" || die "new bundle does not decrypt; bundle untouched"
  [[ "$(sops -d "$BUNDLE" | yq '.trustdinfo.token' | sha12)" == "$(sops -d "$RUN/new.sops.yaml" | yq '.token' | sha12)" ]] && ok "bundle token = new token" || bad "bundle token not updated"
  [[ "$(sops -d "$BUNDLE" | yq 'del(.trustdinfo.token)' | sha12)" == "$before" ]] && ok "every other bundle field unchanged" || bad "other bundle fields changed"
  finish_step token-bundle
}
cmd_token_apply() {
  local n=${1:?node}; local ip; ip=$(node_ip "$n"); header token-apply "$n"; need token-bundle
  [[ "$(state_get "token-apply.$n")" != verified ]] || die "token-apply already verified on $n"
  local rc; rc=$(topf_dry "^$n\$"); log "- dry-run rc=$rc"
  local other; other=$(changed_lines | grep -vE '^[-+] *token: |redacted|\*\*\*' || true)
  [[ $rc == 2 && -z "$other" && $(changed_lines | wc -l) -le 2 ]] && ok "diff changes only machine.token" || die "unexpected diff on $n (rc=$rc); nothing applied"
  topf apply --nodes-filter "^$n\$" --mode no-reboot --confirm=false 2>&1 | scrub | grep -E 'level=|rror' | tee -a "$RUN/log.md"
  state_set "token-apply.$n" applied
  sleep 5; check_token_apply "$n"
}
check_token_apply() {
  local n=$1 ip; ip=$(node_ip "$n"); FAILED=0; log "- checks for token-apply on $n:"
  [[ "$(node_token_hash "$CURRENT_TC" "$ip")" == "$(sops -d "$BUNDLE" | yq '.trustdinfo.token' | sha12)" ]] && ok "$n: running token = bundle token" || bad "$n: running token differs"
  talosctl --talosconfig "$CURRENT_TC" -n "$ip" -e "$ip" service trustd 2>/dev/null | grep -qE 'STATE +Running' && ok "$n: trustd Running" || bad "$n: trustd not Running"
  talos_ok "$CURRENT_TC" "$ip" && ok "$n: talosconfig works" || bad "$n: talosconfig fails"
  common_health "$CURRENT_TC" "$ip"
  finish_step "token-apply.$n"
}

# Step 7: final proof and cleanup of the temporary client configs.
cmd_finish() {
  header finish; local n ip; for n in $(node_names); do need "token-apply.$n"; done
  local rc; rc=$(topf_dry '.*'); [[ $rc == 0 ]] && ok "topf dry-run: no drift on any node" || bad "topf dry-run rc=$rc"
  for n in $(node_names); do ip=$(node_ip "$n")
    talos_ok "$CURRENT_TC" "$ip" && ok "$n: talosconfig works" || bad "$n: talosconfig fails"
    talos_ok "$RUN/talosconfig.oldcert-dual" "$ip" && bad "$n: old CA client cert accepted" || ok "$n: old CA client cert rejected"
  done
  common_health "$CURRENT_TC" "$(node_ip "$(node_names | head -1)")"
  if [[ $FAILED -eq 0 ]]; then
    shred -u "$RUN/talosconfig.new" "$RUN/talosconfig.dual" "$RUN/talosconfig.oldcert-dual"
    ok "shredded the temporary talosconfigs"
    info "kept (sops-encrypted): secrets.before.sops.yaml, talosconfig.old.sops.yaml, new.sops.yaml; remove after the PR merges: just talos rotate cleanup"
  fi
  finish_step finish
}

cmd_cleanup() {
  header cleanup; need finish
  rm -f "$RUN/secrets.before.sops.yaml" "$RUN/talosconfig.old.sops.yaml" "$RUN/new.sops.yaml"
  ok "removed the encrypted backups (old CA key is dead; new material lives in the bundle)"
  local id; id=$(basename "$(readlink -f "$RUN")"); rm "$RUN"; log "- run $id closed; log kept at rotation/$id/log.md"
}

cmd_check() { # re-run a step's checks without changing anything
  local step=${1:?step} n=${2:-}; header "check $step $n"
  case $step in
    accept-new) check_accept_new "${n:?node}" ;; issue-new) check_issue_new "${n:?node}" ;;
    drop-old) check_drop_old "${n:?node}" ;; token-apply) check_token_apply "${n:?node}" ;;
    *) die "no standalone check for '$step'" ;;
  esac
}

case "${1:-status}" in
  status) cmd_status ;; prep) cmd_prep ;; generate) cmd_generate ;;
  accept-new) cmd_accept_new "${2:-}" ;; swap-bundle) cmd_swap_bundle ;; issue-new) cmd_issue_new "${2:-}" ;;
  verify) cmd_verify ;; drop-old) cmd_drop_old "${2:-}" ;;
  token-bundle) cmd_token_bundle ;; token-apply) cmd_token_apply "${2:-}" ;;
  finish) cmd_finish ;; cleanup) cmd_cleanup ;; check) shift; cmd_check "$@" ;;
  *) echo "usage: $0 {status|prep|generate|accept-new <node>|swap-bundle|issue-new <node>|verify|drop-old <node>|token-bundle|token-apply <node>|finish|cleanup|check <step> <node>}" >&2; exit 2 ;;
esac
