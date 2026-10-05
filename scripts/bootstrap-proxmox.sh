#!/usr/bin/env bash
#
# Sets up everything this lab needs on a Proxmox host. Safe to re-run.
#
#   - checks the host prerequisites from prepare-proxmox.sh
#   - builds the lab network: SDN zone, the underlay and external vnets, the
#     SNAT unit and, once the VPC exists, the routes to the overlay subnets
#   - creates the resource pool and a Terraform API user and token
#   - limits the token to that pool, the datastore, the ISO storage and the
#     zones of the two bridges
#   - checks the installer ISO exists and the VMIDs are free
#   - writes the new token to secret.tfvars
#
# Settings are read from terraform.tfvars, falling back to the defaults in
# variables.tf, so there is a single source of truth. The network settings
# are in network.conf.
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

echo "Bootstrapping $TARGET (zone $SDN_ZONE, pool $POOL, user $TF_USER, token $TOKEN_NAME)"

env_vars=()
while IFS= read -r line; do env_vars+=("$line"); done \
  < <(remote_env POOL DATASTORE ISO VM_ID_START NODE_COUNT BRIDGE EXTERNAL_BRIDGE TF_USER TOKEN_NAME ROTATE \
    SDN_ZONE UNDERLAY_SUBNET UNDERLAY_GATEWAY EXTERNAL_SUBNET EXTERNAL_GATEWAY LAB_RANGE OVERLAY_SUBNETS VPC_ROUTER_IP)

# Everything between the EOF markers runs on the Proxmox host; only the token
# JSON (if one was created) is printed to stdout, everything else to stderr
output=$(ssh "$TARGET" env "${env_vars[@]}" bash -s <<'EOF'
set -euo pipefail
log() { echo "  $*" >&2; }

exists() { pvesh get "$1" >/dev/null 2>&1; }
fail() {
  log "ERROR: $*"
  exit 1
}

# Host prerequisites, set up once by prepare-proxmox.sh
nested=$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null || true)
[[ "$nested" =~ ^(Y|1)$ ]] || fail "nested virtualisation is not enabled – run scripts/prepare-proxmox.sh first"
[[ "$(sysctl -n net.ipv4.ip_forward)" == 1 ]] || fail "IPv4 forwarding is off – run scripts/prepare-proxmox.sh first"
log "host prerequisites: ok"

# Lab network. A bridge that already exists is used as it is; otherwise it is
# created as a vnet in the lab's SDN zone, with the host as gateway. No
# per-subnet snat and no DHCP: NAT is done once for the whole lab range by the
# unit below, and every Nutanix address is static
sdn_changed=0
zones=()
vnet() {
  local name=$1 alias=$2 subnet=$3 gateway=$4 zone
  zone=$(pvesh get "/cluster/sdn/vnets/$name" --output-format json 2>/dev/null |
    perl -MJSON -0e 'print decode_json(<STDIN>)->{zone}' 2>/dev/null || true)
  if [[ -n "$zone" ]]; then
    log "vnet $name: exists in zone $zone"
  elif [[ -d "/sys/class/net/$name/bridge" ]]; then
    # Proxmox files plain Linux bridges under the built-in zone "localnetwork"
    zone=localnetwork
    log "bridge $name: exists, not managed by SDN"
  else
    zone=$SDN_ZONE
    if ! exists "/cluster/sdn/zones/$zone"; then
      pvesh create /cluster/sdn/zones --zone "$zone" --type simple --ipam pve >&2
      log "zone $zone: created"
    fi
    pvesh create /cluster/sdn/vnets --vnet "$name" --zone "$zone" --alias "$alias" >&2
    sdn_changed=1
    log "vnet $name: created in zone $zone"
  fi
  if [[ "$zone" == "$SDN_ZONE" ]] && ! exists "/cluster/sdn/vnets/$name/subnets/$zone-${subnet/\//-}"; then
    pvesh create "/cluster/sdn/vnets/$name/subnets" --type subnet --subnet "$subnet" --gateway "$gateway" >&2
    sdn_changed=1
    log "subnet $subnet: created on $name, gateway $gateway"
  fi
  # Configured but never applied, e.g. after an interrupted run
  [[ -d "/sys/class/net/$name" ]] || sdn_changed=1
  [[ " ${zones[*]-} " == *" $zone "* ]] || zones+=("$zone")
}
vnet "$BRIDGE" "Nutanix underlay" "$UNDERLAY_SUBNET" "$UNDERLAY_GATEWAY"
vnet "$EXTERNAL_BRIDGE" "Nutanix external" "$EXTERNAL_SUBNET" "$EXTERNAL_GATEWAY"

# Routes to the overlay subnets, via the VPC's address on the external subnet.
# SDN regenerates frr.conf on every apply and merges frr.conf.local into it
frr_local=/etc/frr/frr.conf.local
frr_marker="! Managed by nutanix-lab (scripts/bootstrap-proxmox.sh)"
if [[ -n "$VPC_ROUTER_IP" ]]; then
  [[ -x /usr/lib/frr/frr-reload.py ]] || fail "FRR is not installed – run scripts/prepare-proxmox.sh first"
  if [[ -e "$frr_local" ]] && ! grep -qxF "$frr_marker" "$frr_local"; then
    fail "$frr_local exists and is not from this lab – add the overlay routes to it by hand"
  fi
  routes=$(
    echo "$frr_marker"
    for subnet in $OVERLAY_SUBNETS; do echo "ip route $subnet $VPC_ROUTER_IP"; done
  )
  if [[ "$routes" != "$(cat "$frr_local" 2>/dev/null)" ]]; then
    echo "$routes" >"$frr_local"
    chown frr:frr "$frr_local"
    chmod 640 "$frr_local"
    sdn_changed=1
  fi
  log "overlay routes: $OVERLAY_SUBNETS via $VPC_ROUTER_IP"
else
  log "overlay routes: none yet, VPC_ROUTER_IP is not set in network.conf"
fi

if [[ "$sdn_changed" == 1 ]]; then
  pvesh set /cluster/sdn >/dev/null
  for _ in {1..30}; do
    [[ -d "/sys/class/net/$BRIDGE" && -d "/sys/class/net/$EXTERNAL_BRIDGE" ]] && break
    sleep 1
  done
  [[ -d "/sys/class/net/$BRIDGE" && -d "/sys/class/net/$EXTERNAL_BRIDGE" ]] ||
    fail "$BRIDGE or $EXTERNAL_BRIDGE did not come up after applying SDN"
  log "SDN: applied"
fi

# One SNAT rule for the whole lab range, on the interface of the default
# route. It covers lab traffic to the internet and connections the lab opens
# to the LAN; replies to connections opened from the LAN are not NATed
read -r uplink uplink_ip < <(ip -4 route get 1.1.1.1 2>/dev/null | awk '{
  for (i = 1; i < NF; i++) { if ($i == "dev") dev = $(i + 1); if ($i == "src") src = $(i + 1) }
} END { print dev, src }') || true
[[ -n "${uplink:-}" && -n "${uplink_ip:-}" ]] || fail "the host has no default route to NAT the lab to"
nat_unit=/etc/systemd/system/nutanix-lab-nat.service
nat_rule="POSTROUTING -s $LAB_RANGE -o $uplink -j SNAT --to-source $uplink_ip"
nat_content=$(
  cat <<UNIT
[Unit]
Description=SNAT for the Nutanix lab ($LAB_RANGE)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/iptables -w -t nat -A $nat_rule
ExecStop=-/usr/sbin/iptables -w -t nat -D $nat_rule

[Install]
WantedBy=multi-user.target
UNIT
)
if [[ "$nat_content" != "$(cat "$nat_unit" 2>/dev/null)" ]]; then
  # Stop a previous version first, so that it removes its own rule
  if [[ -e "$nat_unit" ]]; then systemctl stop nutanix-lab-nat.service; fi
  echo "$nat_content" >"$nat_unit"
  systemctl daemon-reload
fi
systemctl enable -q --now nutanix-lab-nat.service
log "NAT: $LAB_RANGE leaves $uplink as $uplink_ip"

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
# PVEPoolUser lets the provider read the pool's members; without it every
# plan wants to put the VMs back into the pool
pveum acl modify "/pool/$POOL" --users "$TF_USER" --roles PVEVMAdmin,PVEPoolUser
pveum acl modify "/storage/$DATASTORE" --users "$TF_USER" --roles PVEDatastoreUser
pveum acl modify "/storage/$iso_storage" --users "$TF_USER" --roles PVEDatastoreUser
for zone in "${zones[@]}"; do
  pveum acl modify "/sdn/zones/$zone" --users "$TF_USER" --roles PVESDNUser
done
# A new VM only joins the pool at the end of creation, so the options set
# while creating it are checked against /vms/<id> rather than the pool
for ((id = VM_ID_START; id < VM_ID_START + NODE_COUNT; id++)); do
  pveum acl modify "/vms/$id" --users "$TF_USER" --roles PVEVMAdmin
done
log "permissions: pool $POOL, VMIDs $VM_ID_START-$((VM_ID_START + NODE_COUNT - 1)), storage $DATASTORE and $iso_storage, zone ${zones[*]}"

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
