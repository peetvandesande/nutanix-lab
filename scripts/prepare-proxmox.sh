#!/usr/bin/env bash
#
# One-time preparation of a Proxmox host for nested, routed labs like this
# one. Safe to re-run. Nothing here is specific to this lab, and
# ansible/teardown.yml leaves it all in place.
#
#   - enables nested virtualisation
#   - turns on IPv4 forwarding, so the host routes between the LAN and the lab
#   - installs FRR, which holds the static routes to networks behind the lab
#
# Usage: scripts/prepare-proxmox.sh [ssh-target]
#   ssh-target defaults to root@<host from pm_endpoint>

set -euo pipefail

source "$(dirname "$0")/lib.sh"

load_config "$@"

echo "Preparing $TARGET"

ssh "$TARGET" bash -s <<'EOF'
set -euo pipefail
log() { echo "  $*"; }

if grep -qw vmx /proc/cpuinfo; then
  module=kvm_intel
elif grep -qw svm /proc/cpuinfo; then
  module=kvm_amd
else
  log "ERROR: this CPU has no virtualisation extensions"
  exit 1
fi
nested=$(cat "/sys/module/$module/parameters/nested" 2>/dev/null || true)
if [[ "$nested" =~ ^(Y|1)$ ]]; then
  log "nested virtualisation: enabled"
else
  echo "options $module nested=1" >/etc/modprobe.d/kvm-nested.conf
  # The module can only be reloaded while no VM is using it
  if qm list | grep -qw running; then
    log "nested virtualisation: configured, but VMs are running – reboot the host to enable it"
  else
    modprobe -r "$module"
    modprobe "$module"
    log "nested virtualisation: enabled"
  fi
fi

# SDN only enables forwarding on its own vnets; traffic from the LAN arrives
# on the host's main bridge
echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/90-ip-forward.conf
sysctl -q -p /etc/sysctl.d/90-ip-forward.conf
log "IPv4 forwarding: on"

if [[ -x /usr/lib/frr/frr-reload.py ]]; then
  log "FRR: installed"
else
  apt-get update -q >/dev/null || log "WARNING: apt-get update failed, trying to install FRR anyway"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q frr frr-pythontools >/dev/null
  log "FRR: installed"
fi
EOF

echo "Done. Next: ansible-playbook ansible/bootstrap.yml"
