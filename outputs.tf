output "nodes" {
  description = "Nutanix CE nodes with their VMID and the MAC address of each NIC, to tell eth0 from eth1 inside AHV"
  value = {
    for name, vm in proxmox_virtual_environment_vm.nutanix_ce : name => {
      vm_id        = vm.vm_id
      underlay_mac = vm.network_device[0].mac_address
      external_mac = vm.network_device[1].mac_address
    }
  }
}
