#!/usr/bin/env bash
#
# Removes everything this project created on the Proxmox host – the reverse
# of bootstrap-proxmox.sh.
#
#   - destroys the VMs through Terraform/OpenTofu, while the token still works
#   - stops if any VM is still left in the pool
#   - removes the token, its permissions and the pool
#   - removes the Terraform user, unless another project still uses it
#   - removes the lab network: SNAT unit, overlay routes and SDN zone
#   - deletes the local state files and secret.tfvars
#
# The installer ISO is left alone, and so is the host preparation from
# prepare-proxmox.sh (nested virtualisation, IPv4 forwarding, FRR), which is
# not specific to this lab.
#
# Usage: scripts/teardown-proxmox.sh [ssh-target]
#   ssh-target defaults to root@<host from pm_endpoint>

set -euo pipefail

source "$(dirname "$0")/lib.sh"

load_config "$@"

TF_BIN=${TF_BIN:-$(command -v tofu || command -v terraform || true)}

echo "Tearing down $TARGET (pool $POOL, user $TF_USER, token $TOKEN_NAME)"
read -r -p "This deletes the lab VMs and their disks. Type the pool name to continue: " answer
[[ "$answer" == "$POOL" ]] || { echo "Aborted."; exit 1; }

# 1. VMs, through the tool that created them
if [[ -f terraform.tfstate ]] && grep -q '"type": "proxmox_' terraform.tfstate; then
  [[ -n "$TF_BIN" ]] || { echo "State has VMs but neither tofu nor terraform is installed" >&2; exit 1; }
  echo "Destroying VMs with $TF_BIN"
  "$TF_BIN" destroy -auto-approve -var-file=secret.tfvars
else
  echo "No VMs in state, skipping destroy"
fi

# 2. Everything on the Proxmox host
env_vars=()
while IFS= read -r line; do env_vars+=("$line"); done \
  < <(remote_env POOL DATASTORE ISO VM_ID_START NODE_COUNT TF_USER TOKEN_NAME SDN_ZONE)

ssh "$TARGET" env "${env_vars[@]}" bash -s <<'EOF'
set -euo pipefail
log() { echo "  $*"; }

# Refuse to continue while the pool still holds VMs Terraform did not remove
left=$(pvesh get /cluster/resources --type vm --output-format json |
  perl -MJSON -0e 'print "$_->{vmid} " for grep { ($_->{pool} // "") eq $ENV{POOL} } @{decode_json(<STDIN>)}')
if [[ -n "$left" ]]; then
  log "ERROR: pool $POOL still contains VMs: $left"
  log "Remove them (qm destroy <id> --purge) and re-run."
  exit 1
fi

if pveum user token list "$TF_USER" --output-format json 2>/dev/null | grep -q "\"tokenid\":\"$TOKEN_NAME\""; then
  pveum user token remove "$TF_USER" "$TOKEN_NAME"
  log "token $TOKEN_NAME: removed"
fi

# Ignore entries that are already gone, e.g. /vms/<id>, which Proxmox drops
# when the VM is destroyed
iso_storage=${ISO%%:*}
revoke() { pveum acl delete "$1" --users "$TF_USER" --roles "$2" 2>/dev/null || true; }
revoke "/pool/$POOL" PVEVMAdmin,PVEPoolUser
revoke "/sdn/zones/$SDN_ZONE" PVESDNUser
for ((id = VM_ID_START; id < VM_ID_START + NODE_COUNT; id++)); do
  revoke "/vms/$id" PVEVMAdmin
done
log "permissions: pool $POOL, zone $SDN_ZONE and VMIDs $VM_ID_START-$((VM_ID_START + NODE_COUNT - 1)) revoked"

if pveum pool list --output-format json | grep -q "\"poolid\":\"$POOL\""; then
  pveum pool delete "$POOL"
  log "pool $POOL: removed"
fi

# The user, storage and zone permissions may be shared with other projects
# using the same Terraform user; only remove them once no tokens are left
if pveum user list --output-format json | grep -q "\"userid\":\"$TF_USER\""; then
  if pveum user token list "$TF_USER" --output-format json | grep -q '"tokenid"'; then
    log "user $TF_USER: kept, other projects still have tokens"
  else
    revoke "/storage/$DATASTORE" PVEDatastoreUser
    revoke "/storage/$iso_storage" PVEDatastoreUser
    revoke /sdn/zones/localnetwork PVESDNUser
    pveum user delete "$TF_USER"
    log "user $TF_USER: removed with its remaining permissions"
  fi
fi

# The lab network. Stopping the unit removes its SNAT rule
if [[ -e /etc/systemd/system/nutanix-lab-nat.service ]]; then
  systemctl disable -q --now nutanix-lab-nat.service
  rm /etc/systemd/system/nutanix-lab-nat.service
  systemctl daemon-reload
  log "NAT: removed"
fi

sdn_changed=0
if grep -qs '^! Managed by nutanix-lab' /etc/frr/frr.conf.local; then
  rm /etc/frr/frr.conf.local
  sdn_changed=1
  log "overlay routes: removed"
fi
if pvesh get "/cluster/sdn/zones/$SDN_ZONE" >/dev/null 2>&1; then
  vnets=$(pvesh get /cluster/sdn/vnets --output-format json |
    perl -MJSON -0e 'print "$_->{vnet}\n" for grep { $_->{zone} eq $ENV{SDN_ZONE} } @{decode_json(<STDIN>)}')
  for vnet in $vnets; do
    subnets=$(pvesh get "/cluster/sdn/vnets/$vnet/subnets" --output-format json |
      perl -MJSON -0e 'print "$_->{subnet}\n" for @{decode_json(<STDIN>)}')
    for subnet in $subnets; do
      pvesh delete "/cluster/sdn/vnets/$vnet/subnets/$subnet"
    done
    pvesh delete "/cluster/sdn/vnets/$vnet"
  done
  pvesh delete "/cluster/sdn/zones/$SDN_ZONE"
  sdn_changed=1
  log "zone $SDN_ZONE: removed with its vnets"
fi
# Also regenerates frr.conf without the overlay routes
if [[ "$sdn_changed" == 1 ]]; then
  pvesh set /cluster/sdn >/dev/null
  log "SDN: applied"
fi
EOF

# 3. Local files that only make sense while the lab exists
rm -f terraform.tfstate terraform.tfstate.backup secret.tfvars
echo "Removed local state and secret.tfvars"

echo "Done. The lab has been removed from $TARGET."
