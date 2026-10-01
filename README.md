# nutanix-lab

Terraform for a Nutanix CE cluster running as nested VMs on Proxmox VE.

Terraform only manages the VMs it creates. The API token is limited to one resource pool, so it cannot touch other VMs on the host.

## Requirements

- Terraform 1.5 or later
- SSH access as root to the Proxmox host (for the bootstrap only)
- The Nutanix CE installer ISO uploaded to a Proxmox ISO storage

## Usage

1. Configure the project:

   ```sh
   cp terraform.tfvars.example terraform.tfvars
   ```

   Set the endpoint, node, ISO and a free `vm_id_start`. For another project, change `pool_id` and `name_prefix` as well.

2. Prepare Proxmox:

   ```sh
   scripts/bootstrap-proxmox.sh
   ```

   This checks nested virtualisation, creates the pool, a `terraform@pve` user and an API token, grants the minimum permissions, checks the ISO and VMIDs, and writes the token to `secret.tfvars`. It reads its settings from `terraform.tfvars` and is safe to re-run. Use `--rotate-token` to replace the token.

3. Create the VMs:

   ```sh
   terraform init
   terraform plan  -var-file=secret.tfvars   # only "+ create" expected
   terraform apply -var-file=secret.tfvars
   ```

4. Install CE on each node from the Proxmox console, then create the cluster from one of the CVMs.

## Removing the lab

```sh
scripts/teardown-proxmox.sh
```

This destroys the VMs, then removes the token, permissions, pool and (if no other project uses it) the Terraform user, and deletes the local state and `secret.tfvars`. The ISO is left in place.

## IP addresses

Each node needs a static IP for the AHV host and one for the CVM, plus one cluster virtual IP – 7 in total for 3 nodes.
