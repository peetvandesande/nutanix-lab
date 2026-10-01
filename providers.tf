terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.114.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.pm_endpoint
  api_token = var.pm_api_token
  insecure  = var.pm_insecure
}
