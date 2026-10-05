# Network plan: Proxmox SDN + Nutanix Flow Virtual Networking

Instructions for a Claude session building the lab network. Load with
`@NETWORK.md`. The design decisions below are settled; the steps are not yet
done. **Explain each phase to the user and get a go-ahead before changing
anything on lenora, the router or the cluster.**

Written 2026-10-02.

## Goal

- The Nutanix nodes (AHV hosts and CVMs) live on an **underlay** network,
  `192.168.33.0/24`, separate from the home LAN.
- The Nutanix VMs live on **three overlay subnets**, `192.168.34.0/24`,
  `.35.0/24` and `.36.0/24`, inside one VPC. **Nutanix routes between them**
  (Flow Virtual Networking), not Proxmox.
- **Proxmox (lenora) routes between the LAN and the lab.**

## Decisions and why

| Decision | Reason |
|---|---|
| Overlay subnets in a VPC, not VLAN subnets | Plain AHV VLAN subnets are L2 only; something outside Nutanix would have to route them. Only Flow Virtual Networking (FVN) makes Nutanix the router. |
| Prism Central is required | FVN is configured and run from PC. |
| Separate transit network `192.168.37.0/24` for the VPC uplink | The FVN external subnet must be VLAN-backed. Keeping it off the CVM/AHV management network avoids mixing it with management traffic. Each node gets a second NIC for it. |
| Proxmox **Simple** zone | All three nodes run on lenora, so a host-local bridge with lenora as gateway is enough. VLAN/VXLAN/EVPN zones only help with multiple Proxmox hosts. |
| MTU 1500 everywhere | FVN automatically lowers the overlay subnet MTU (to 1442) to fit the Geneve header. Jumbo frames would mean changing the CVM MTU, which CE does not support well. Not worth it in a lab. |
| VPC in **No-NAT** mode | So LAN clients can reach VM IPs directly. |
| NAT to the internet done by lenora, not the router | The router may not NAT subnets it isn't directly connected to. One SNAT rule on lenora covers the whole lab. |
| Node disks on `hddpool`, 64 GB RAM per node | Agreed with the user; ssdpool lacks space. Slow, acceptable for a lab. 64 GB so a Small Prism Central fits next to a CVM – X-Small does not support FVN. |
| Host setup split over two scripts | `scripts/prepare-proxmox.sh` does the one-time, lab-independent host preparation (nested virtualisation, IPv4 forwarding, FRR). `scripts/bootstrap-proxmox.sh` does everything specific to this lab, including the whole of Phase 1's SDN, NAT and routes, from the settings in `network.conf`. Teardown reverses only the bootstrap. |

## Current state (2026-10-02)

- **Phases 1 and 2 are done.** Zone `ntnx` with vnets `ntnxul` (.33.1) and
  `ntnxext` (.37.1) exists, `net.ipv4.ip_forward = 1`, and
  `nutanix-lab-nat.service` is enabled and active.
- Pool `nutanix-lab`, user `terraform@pve` and its token exist. The three
  nodes (VMIDs 9101-9103, 64 GB each, on `hddpool`) were created once with
  OpenTofu (`tofu`; `terraform` is not installed on the workstation),
  destroyed at the user's request and re-created as UEFI machines (OVMF on
  q35, Secure Boot off). They are sitting in the CE installer.
  `tofu output nodes` lists their MACs.
- After any `tofu destroy`, re-run the bootstrap before applying again:
  Proxmox drops the `/vms/<id>` ACLs when a VM is destroyed.
- Not done yet: the LAN-side route (user), the CE install and cluster
  (Phase 3), Prism Central and FVN (Phase 4), and the FRR routes to the
  overlay, which wait for `VPC_ROUTER_IP`.
- Still open: whether FVN accepts VLAN 0 for the external subnet (Phase 4,
  step 4), and whether SDN really merges `frr.conf.local` when no SDN
  controller is defined.
- ISO: `isos:iso/phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso` (CE 2.1,
  AOS 6.8.1). Nested virtualisation enabled (`kvm_intel nested=Y`).

Re-check all of this before continuing – `pvesh get /cluster/sdn/zones`,
`sysctl net.ipv4.ip_forward`, `qm list`, `pveum pool list`.

## Address plan

```
LAN 192.168.1.0/24 ── router .1
      │   route 192.168.32.0/21 → 192.168.1.21  (router or client side)
lenora vmbr0 192.168.1.21
      │   forwarding on, SNAT 192.168.32.0/21 → 192.168.1.21
      ├── vnet ntnxul   192.168.33.0/24  lenora .1   (net0 of each node)
      └── vnet ntnxext  192.168.37.0/24  lenora .1   (net1 of each node)
                                │
                    VPC "lab" (No-NAT), external IP on .37
                     ├── 192.168.34.0/24
                     ├── 192.168.35.0/24
                     └── 192.168.36.0/24
```

`192.168.32.0/21` covers .32-.39, so one route and one NAT rule cover
everything.

**Underlay `192.168.33.0/24`**

| Address | Use |
|---|---|
| .1 | lenora (gateway) |
| .11 / .12 / .13 | AHV hosts ntnx-ce-1/2/3 |
| .21 / .22 / .23 | CVMs |
| .30 | Cluster virtual IP |
| .31 | iSCSI data services IP (needed to deploy PC) |
| .40 | Prism Central |
| .41-.49 | Reserved (PC scale-out/VIP) |

**Transit `192.168.37.0/24`**: .1 lenora; .100-.199 Nutanix external IP
pool (the VPC's uplink IP comes from here).

**Overlay subnets**: gateway `.1` in each (owned by the VPC router), DHCP
pool `.100-.199`.

**DNS** for nodes and VMs: `192.168.1.1`. Not Themis; see the homelab
CLAUDE.md – the DHCP cutover has not happened. NTP: `pool.ntp.org`.

## Phase 1 – Proxmox SDN (on lenora)

Done by running `scripts/prepare-proxmox.sh` (forwarding, FRR) and then
`scripts/bootstrap-proxmox.sh` (SDN, NAT unit, routes). The commands below
describe what those scripts do; don't run them by hand.

IDs: zone ≤ 8 chars, vnet ≤ 8 chars, lowercase.

```sh
pvesh create /cluster/sdn/zones --zone ntnx --type simple --ipam pve
pvesh create /cluster/sdn/vnets --vnet ntnxul  --zone ntnx --alias "Nutanix underlay"
pvesh create /cluster/sdn/vnets --vnet ntnxext --zone ntnx --alias "Nutanix external"
pvesh create /cluster/sdn/vnets/ntnxul/subnets  --type subnet --subnet 192.168.33.0/24 --gateway 192.168.33.1
pvesh create /cluster/sdn/vnets/ntnxext/subnets --type subnet --subnet 192.168.37.0/24 --gateway 192.168.37.1
pvesh set /cluster/sdn        # apply
```

Leave SDN's per-subnet `snat` **off**. It only matches the subnet it is set
on, so it would miss the overlay ranges, which reach lenora with their own
source addresses. NAT is handled once, below. No DHCP in the zone – every
Nutanix address is static.

**Forwarding.** SDN sets `ip-forward on` on the vnet bridges only. Traffic
from the LAN arrives on `vmbr0`, so global forwarding is needed too:

```sh
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-ip-forward.conf
sysctl -p /etc/sysctl.d/90-ip-forward.conf
```

**NAT.** Use a systemd oneshot, `nutanix-lab-nat.service`, `After=network-online.target`,
`RemainAfterExit=yes`. It should add, and remove on stop:

```
iptables -t nat -A POSTROUTING -s 192.168.32.0/21 -o vmbr0 -j SNAT --to-source 192.168.1.21
```

This catches traffic going out to the internet *and* traffic the lab starts
towards the LAN. Replies to connections the LAN starts are tracked by conntrack
and are not NATed, so inbound access still shows the real addresses.

**Routes to the overlay** (Phase 4 gives the next hop, the VPC's external
IP on .37). Prefer FRR over a plain `ip route`, so the route comes back if SDN
recreates the bridge:

- Put the routes in `/etc/frr/frr.conf.local`, **not** `frr.conf`. PVE SDN
  regenerates `frr.conf` on every apply and is meant to merge the `.local`
  file in. **Verify that** after an apply, and check `staticd` is enabled in
  `/etc/frr/daemons`.
  ```
  ip route 192.168.34.0/24 192.168.37.<vpc-ip>
  ip route 192.168.35.0/24 192.168.37.<vpc-ip>
  ip route 192.168.36.0/24 192.168.37.<vpc-ip>
  ```
- If FRR fights you, fall back to `ip route replace` lines in the NAT unit,
  with `PartOf=`/re-run after `pvesh set /cluster/sdn`.
- The bootstrap writes `frr.conf.local` once `VPC_ROUTER_IP` is set in
  `network.conf`. The SNAT unit's interface and source address are taken
  from the host's default route.

`scripts/teardown-proxmox.sh` removes the unit, `frr.conf.local` and the SDN
zone. It leaves forwarding on, as that is host preparation.

**Router / LAN side.** This needs the user – don't attempt it. Either:
- a static route on the router, `192.168.32.0/21 via 192.168.1.21`, if it
  supports one, or
- a route on the workstation only (macOS:
  `sudo route -n add -net 192.168.32.0/21 192.168.1.21`).

Without it, only lenora can reach the lab. Outbound from the lab works
regardless, thanks to the SNAT.

**Verify Phase 1:** `ip -br addr show ntnxul ntnxext` shows .33.1 / .37.1;
`iptables -t nat -S POSTROUTING` shows the rule; `sysctl net.ipv4.ip_forward` is 1.

## Phase 2 – Terraform changes (this repo)

- `bridge` default → `ntnxul`. Add `external_bridge` (default `ntnxext`)
  and a second `network_device` on it. Set `firewall = false` on both, or
  the Proxmox firewall's MAC filtering drops traffic from nested VMs. Drop
  `vlan_id` unless still wanted. Keep `model = "e1000"`.
- `outputs.tf`: output both MACs per node. They are needed to tell eth0 from
  eth1 inside AHV.
- `terraform.tfvars` (and the `.example`): `datastore_id = "hddpool"`,
  `memory_mb = 65536`.
- `scripts/bootstrap-proxmox.sh`: grant `PVESDNUser` on `/sdn/zones/ntnx`.
  Today it only grants `localnetwork`, so attaching to the vnets would be
  denied.
- Update the README (network section, IP addresses).

These edits were made on 2026-10-02 (uncommitted at the time of writing);
nothing has been applied yet.

Run the bootstrap, then `terraform plan` (expect only creates) and show the
user the plan before `apply`.

## Phase 3 – CE install and cluster

On each node's console: install CE with the AHV/CVM IPs above, gateway
`192.168.33.1`, netmask /24. Do **not** create a single-node cluster from the
installer. Then from one CVM:

```sh
cluster -s 192.168.33.21,192.168.33.22,192.168.33.23 --redundancy_factor=2 create
```

Then in Prism Element: cluster VIP `.30`, data services IP `.31`, DNS
`192.168.1.1`, NTP.

**Second uplink:** make sure AHV's `eth0` (MAC of net0) is the only uplink of
`vs0`/`br0`. Then create virtual switch **`vs1`** with `eth1` on every
host, single uplink, active-backup. If the installer pulled both NICs into
`br0`, take `eth1` out first. Check with `manage_ovs show_uplinks` on a CVM.

## Phase 4 – Prism Central and FVN

1. Deploy Prism Central from Prism Element onto the underlay, IP `.33.40`.
   pc.2024.1.0.2 is reported to work on CE 2.1 / AOS 6.8.1; CE offers no PC
   version by default, so upload the binary and metadata file from the
   Nutanix portal in Prism Element. Re-check compatibility before deploying.
2. **Sizing:** X-Small PC (18 GB) does not support FVN, so deploy **Small**
   (~26 GB, plus reportedly ~3 GB once the network controller is enabled –
   not confirmed for pc.2024). The nodes have 64 GB for this reason.
3. Register the cluster with PC and enable **Flow Virtual Networking** /
   Advanced Networking. The menu path depends on the PC version, so look it up.
   Don't guess.
4. **External subnet** on `vs1`: `192.168.37.0/24`, gateway `.1`, IP pool
   `.100-.199`, **NAT off**. Untagged on the Proxmox side, so VLAN 0. **Check
   FVN accepts VLAN 0 for an external subnet.** If it doesn't, stop and
   discuss: the fix is a VLAN-aware vnet plus a tagged gateway interface on
   lenora, which changes Phase 1.
5. **VPC** `lab`, attached to that external subnet, with **externally
   routable prefixes** `192.168.34.0/24`, `.35.0/24`, `.36.0/24` (No-NAT
   requires these to be declared).
6. **Overlay subnets** in the VPC: `192.168.34.0/24`, `.35`, `.36`, gateway
   `.1`, DHCP pool `.100-.199`, DNS `192.168.1.1`.
7. Note the VPC's external IP on .37, set it as `VPC_ROUTER_IP` in
   `network.conf` and re-run the bootstrap to finish the FRR routes from
   Phase 1.

## Phase 5 – Verify

- A VM on .34 can ping a VM on .35 (Nutanix routing).
- A VM on .34 can reach `1.1.1.1` and resolve names (lenora SNAT).
- lenora can ping a VM on .36 (FRR route → VPC).
- The workstation can reach a VM on .34 (needs the LAN-side route).
- `traceroute` from the workstation to a .34 VM goes via 192.168.1.21, then
  192.168.37.x.

## Follow-ups outside this repo

- The homelab repo's `CLAUDE.md` should note that lenora now forwards and
  routes `192.168.32.0/21`, and that `.32-.39` are taken.
- Optional: `home.` DNS records for the nodes/PC (see homelab `dns/`).
