#!/usr/bin/env bash
#
# Prepares a Proxmox host for this Terraform project. Safe to re-run.
#
#   - checks nested virtualisation is enabled
#   - creates the resource pool and a Terraform API user and token
#   - limits the token to that pool, the datastore, the ISO storage and the bridge zone
#   - checks the installer ISO exists and the VMIDs are free
#   - writes the new token to secret.tfvars
#
# Settings are read from terraform.tfvars, falling back to the defaults in
# variables.tf, so there is a single source of truth.
#
# Usage: scripts/bootstrap-proxmox.sh [--rotate-token] [ssh-target]
#   ssh-target defaults to root@<host from pm_endpoint>

set -euo pipefail

source "$(dirname "$0")/lib.sh"

ROTATE=0
if [[ "${1:-}" == "--rotate-token" ]]; then
  ROTATE=1
  shift
fi

load_config "$@"

echo "Bootstrapping $TARGET (pool $POOL, user $TF_USER, token $TOKEN_NAME)"

env_vars=()
while IFS= read -r line; do env_vars+=("$line"); done \
  < <(remote_env POOL DATASTORE ISO VM_ID_START NODE_COUNT TF_USER TOKEN_NAME ROTATE)

# Everything between the EOF markers runs on the Proxmox host; only the token
# JSON (if one was created) is printed to stdout, everything else to stderr
output=$(ssh "$TARGET" env "${env_vars[@]}" bash -s <<'EOF'
set -euo pipefail
log() { echo "  $*" >&2; }

nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null || true)
if [[ "$nested" =~ ^(Y|1)$ ]]; then
  log "nested virtualisation: enabled"
else
  log "WARNING: nested virtualisation is not enabled. With no VMs running:"
  log "  echo 'options kvm_intel nested=1' > /etc/modprobe.d/kvm-nested.conf  (kvm_amd on AMD)"
  log "  modprobe -r kvm_intel && modprobe kvm_intel"
fi

if pveum pool list --output-format json | grep -q "\"poolid\":\"$POOL\""; then
  log "pool $POOL: exists"
else
  pveum pool add "$POOL" --comment "Managed by Terraform"
  log "pool $POOL: created"
fi

if pveum user list --output-format json | grep -q "\"userid\":\"$TF_USER\""; then
  log "user $TF_USER: exists"
else
  pveum user add "$TF_USER" --comment "Terraform"
  log "user $TF_USER: created"
fi

iso_storage=${ISO%%:*}
pveum acl modify "/pool/$POOL" --users "$TF_USER" --roles PVEVMAdmin
pveum acl modify "/storage/$DATASTORE" --users "$TF_USER" --roles PVEDatastoreUser
pveum acl modify "/storage/$iso_storage" --users "$TF_USER" --roles PVEDatastoreUser
pveum acl modify /sdn/zones/localnetwork --users "$TF_USER" --roles PVESDNUser
# A new VM only joins the pool at the end of creation, so the options set
# while creating it are checked against /vms/<id> rather than the pool
for ((id = VM_ID_START; id < VM_ID_START + NODE_COUNT; id++)); do
  pveum acl modify "/vms/$id" --users "$TF_USER" --roles PVEVMAdmin
done
log "permissions: pool $POOL, VMIDs $VM_ID_START-$((VM_ID_START + NODE_COUNT - 1)), storage $DATASTORE and $iso_storage, zone localnetwork"

if pvesm list "$iso_storage" --content iso | awk '{print $1}' | grep -qx "$ISO"; then
  log "ISO $ISO: found"
else
  log "WARNING: ISO $ISO not found – upload it before terraform apply"
fi

# "<vmid> <pool>" for every VM in the cluster
used=$(pvesh get /cluster/resources --type vm --output-format json |
  perl -MJSON -0e 'print "$_->{vmid} ", ($_->{pool} // "-"), "\n" for @{decode_json(<STDIN>)}')
for ((id = VM_ID_START; id < VM_ID_START + NODE_COUNT; id++)); do
  pool=$(awk -v id="$id" '$1 == id { print $2 }' <<<"$used")
  if [[ -z "$pool" ]]; then
    continue
  elif [[ "$pool" == "$POOL" ]]; then
    # Fine if it is ours from an earlier apply
    log "VMID $id: in use by pool $POOL (assumed ours)"
  else
    log "ERROR: VMID $id is already used by a VM outside pool $POOL – change vm_id_start"
    exit 1
  fi
done
log "VMIDs $VM_ID_START-$((VM_ID_START + NODE_COUNT - 1)): ok"

if pveum user token list "$TF_USER" --output-format json | grep -q "\"tokenid\":\"$TOKEN_NAME\""; then
  if [[ "$ROTATE" == 1 ]]; then
    pveum user token remove "$TF_USER" "$TOKEN_NAME"
    log "token $TOKEN_NAME: removed for rotation"
  else
    log "token $TOKEN_NAME: exists (secret cannot be shown again; use --rotate-token for a new one)"
    exit 0
  fi
fi
pveum user token add "$TF_USER" "$TOKEN_NAME" --privsep 0 --comment "Terraform" --output-format json
log "token $TOKEN_NAME: created"
EOF
)

if [[ -n "$output" ]]; then
  token_id=$(grep -o '"full-tokenid":"[^"]*"' <<<"$output" | cut -d'"' -f4)
  secret=$(grep -o '"value":"[^"]*"' <<<"$output" | cut -d'"' -f4)
  line="pm_api_token = \"$token_id=$secret\""

  touch secret.tfvars
  chmod 600 secret.tfvars
  if grep -q '^pm_api_token' secret.tfvars; then
    tmp=$(mktemp)
    awk -v l="$line" '/^pm_api_token/ { print l; next } { print }' secret.tfvars >"$tmp"
    mv "$tmp" secret.tfvars
  else
    echo "$line" >>secret.tfvars
  fi
  echo "Token written to secret.tfvars"
fi

echo "Done. Next: terraform init && terraform plan -var-file=secret.tfvars"
