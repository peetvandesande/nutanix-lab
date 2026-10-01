output "nodes" {
  description = "Nutanix CE nodes with their VMID and MAC address"
  value = {
    for name, vm in proxmox_virtual_environment_vm.nutanix_ce : name => {
      vm_id = vm.vm_id
      mac   = vm.network_device[0].mac_address
    }
  }
}
