locals {
  nodes = {
    for i in range(var.node_count) : "${var.name_prefix}-${i + 1}" => var.vm_id_start + i
  }

  # Nutanix CE needs every disk to have a unique serial number
  disks = {
    sata0 = { role = "boot", size = var.boot_disk_gb }
    sata1 = { role = "cvm", size = var.cvm_disk_gb }
    sata2 = { role = "data", size = var.data_disk_gb }
  }
}

resource "proxmox_virtual_environment_vm" "nutanix_ce" {
  for_each = local.nodes

  name        = each.key
  vm_id       = each.value
  node_name   = var.node_name
  pool_id     = var.pool_id
  description = "Nutanix CE node, managed by Terraform"
  tags        = ["nutanix", "terraform"]

  on_boot         = false
  started         = true
  stop_on_destroy = true

  operating_system {
    type = "l26"
  }

  # Nested virtualisation: CPU type must be host
  cpu {
    type    = "host"
    cores   = var.cores
    sockets = 1
  }

  # No ballooning: the CVM expects its memory to be fixed
  memory {
    dedicated = var.memory_mb
    floating  = 0
  }

  dynamic "disk" {
    for_each = local.disks
    content {
      interface    = disk.key
      datastore_id = var.datastore_id
      size         = disk.value.size
      serial       = "${each.key}-${disk.value.role}"
      ssd          = true
      discard      = "on"
      file_format  = "raw"
    }
  }

  cdrom {
    file_id   = var.iso_file_id
    interface = "ide2"
  }

  # Falls through to the installer while the boot disk is still empty
  boot_order = ["sata0", "ide2"]

  network_device {
    bridge  = var.bridge
    model   = "e1000"
    vlan_id = var.vlan_id
  }

  lifecycle {
    # Swapping or ejecting the ISO after install should not force changes
    ignore_changes = [cdrom]
  }
}
