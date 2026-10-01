variable "pm_username" {
  description = "Proxmox user"
  type = string
  sensitive = true
}

variable "pm_password" {
  description = "Proxmox password"
  type = string
  sensitive = true
}