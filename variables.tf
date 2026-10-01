# Proxmox connection

variable "pm_endpoint" {
  description = "Proxmox API endpoint, without /api2/json, e.g. https://proxmox:8006/"
  type        = string
}

variable "pm_api_token" {
  description = "Proxmox API token, e.g. terraform@pve!nutanix-lab=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  type        = string
  sensitive   = true
}

variable "pm_insecure" {
  description = "Skip TLS verification (only if the Proxmox CA is not in the system trust store)"
  type        = bool
  default     = false
}

# Placement

variable "node_name" {
  description = "Proxmox node to create the VMs on"
  type        = string
}

variable "pool_id" {
  description = "Existing resource pool the VMs are placed in; the API token should only have rights on this pool"
  type        = string
  default     = "nutanix-lab"
}

variable "vm_id_start" {
  description = "First VMID; the cluster uses vm_id_start to vm_id_start + node_count - 1. Make sure these are free."
  type        = number
}

variable "datastore_id" {
  description = "Datastore for the VM disks"
  type        = string
  default     = "local-lvm"
}

variable "iso_file_id" {
  description = "Nutanix CE installer ISO, e.g. isos:iso/phoenix.x86_64-fnd_5.6.1_patch-aos_6.8.1_ga.iso"
  type        = string
}

variable "bridge" {
  description = "Network bridge for the AHV hosts and CVMs"
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "Optional VLAN tag for the cluster network"
  type        = number
  default     = null
}

# Cluster sizing

variable "node_count" {
  description = "Number of Nutanix CE nodes"
  type        = number
  default     = 3
}

variable "name_prefix" {
  description = "VM name prefix; nodes are named <prefix>-1, <prefix>-2, ..."
  type        = string
  default     = "ntnx-ce"

  # Disk serials are "<name>-<role>" and Proxmox allows at most 20 characters
  validation {
    condition     = length(var.name_prefix) <= 10
    error_message = "name_prefix must be 10 characters or fewer."
  }
}

variable "cores" {
  description = "vCPUs per node"
  type        = number
  default     = 8
}

variable "memory_mb" {
  description = "RAM per node in MB (the CVM alone needs around 20 GB)"
  type        = number
  default     = 32768
}

variable "boot_disk_gb" {
  description = "AHV hypervisor boot disk size in GB"
  type        = number
  default     = 64
}

variable "cvm_disk_gb" {
  description = "CVM disk size in GB (presented as SSD)"
  type        = number
  default     = 256
}

variable "data_disk_gb" {
  description = "Data disk size in GB"
  type        = number
  default     = 500
}
