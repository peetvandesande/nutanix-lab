# nutanix-lab

Terraform for a Nutanix CE cluster running as nested VMs on Proxmox VE.

Terraform only manages the VMs it creates. The API token is limited to one resource pool, so it cannot touch other VMs on the host.

## Requirements

- Terraform 1.5 or later
- SSH access as root to the Proxmox host (for the scripts only)
- The Nutanix CE installer ISO uploaded to a Proxmox ISO storage

## Network

The lab uses `192.168.32.0/21`, routed by the Proxmox host. [NETWORK.md](NETWORK.md) has the full design and address plan.

| Network | Range | Routed by |
|---|---|---|
| Underlay (AHV hosts, CVMs, Prism Central) – vnet `ntnxul`, first NIC | `192.168.33.0/24` | Proxmox, gateway `.1` |
| Transit (VPC uplink) – vnet `ntnxext`, second NIC | `192.168.37.0/24` | Proxmox, gateway `.1` |
| Overlay subnets for VMs, in one VPC | `192.168.34.0/24`, `.35.0/24`, `.36.0/24` | Nutanix Flow Virtual Networking |

The Proxmox host forwards between the LAN and the lab and source-NATs lab traffic leaving for the LAN or the internet. To reach the lab from the LAN, add a route for `192.168.32.0/21` via the Proxmox host, on the router or on your workstation.

## Usage

1. Configure the project:

   ```sh
   cp terraform.tfvars.example terraform.tfvars
   ```

   Set the endpoint, node, ISO and a free `vm_id_start`. For another project, change `pool_id` and `name_prefix` as well. The lab's subnets are in `network.conf`; change them if they clash with your LAN.

2. Prepare the Proxmox host – once per host, not per lab:

   ```sh
   scripts/prepare-proxmox.sh
   ```

   This enables nested virtualisation, turns on IPv4 forwarding and installs FRR. None of it is specific to this lab, and the teardown leaves it in place.

3. Set up the lab on Proxmox:

   ```sh
   scripts/bootstrap-proxmox.sh
   ```

   This builds the lab network (SDN zone `ntnx` with the two vnets, and a systemd unit for the NAT rule), creates the pool, a `terraform@pve` user and an API token, grants the minimum permissions, checks the ISO and VMIDs, and writes the token to `secret.tfvars`. It reads its settings from `terraform.tfvars` and `network.conf` and is safe to re-run. Use `--rotate-token` to replace the token.

   Once the VPC exists in Prism Central, set `VPC_ROUTER_IP` in `network.conf` and re-run the bootstrap to add the routes to the overlay subnets.

4. Create the VMs:

   ```sh
   terraform init
   terraform plan  -var-file=secret.tfvars   # only "+ create" expected
   terraform apply -var-file=secret.tfvars
   ```

   The nodes are UEFI machines (OVMF on q35, Secure Boot off). The `nodes` output lists both MAC addresses of each node: `underlay_mac` is `eth0` in AHV, `external_mac` is `eth1`.

   After a `terraform destroy`, re-run the bootstrap before the next apply: Proxmox drops a VM's permissions when the VM is destroyed, and creating it again then fails with a 403.

5. Install CE on each node from the Proxmox console, then create the cluster from one of the CVMs.

## Removing the lab

```sh
scripts/teardown-proxmox.sh
```

This destroys the VMs, then removes the token, permissions, pool and (if no other project uses it) the Terraform user, removes the lab network from the Proxmox host, and deletes the local state and `secret.tfvars`. The ISO and the host preparation from step 2 are left in place.

## IP addresses

All on the underlay, `192.168.33.0/24`, gateway `.1`:

| Address | Use |
|---|---|
| `.11` / `.12` / `.13` | AHV hosts `ntnx-ce-1/2/3` |
| `.21` / `.22` / `.23` | CVMs |
| `.30` | Cluster virtual IP |
| `.31` | iSCSI data services IP |
| `.40` | Prism Central |
