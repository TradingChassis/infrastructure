variable "oci_region" {
  type        = string
  description = "OCI region used by the Terraform OCI provider (for example eu-frankfurt-1)."
}

variable "oci_compartment_id" {
  type        = string
  description = "OCID of the compartment that owns the OCI network and compute resources."
}

variable "name_prefix" {
  type        = string
  description = "Short prefix used for OCI display names (for example tradingchassis)."
  default     = "tradingchassis"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,30}$", var.name_prefix))
    error_message = "name_prefix must be lowercase alphanumeric with optional hyphens, start with a letter, and be at most 31 characters."
  }
}

variable "vcn_cidr" {
  type        = string
  description = "IPv4 CIDR block for the VCN. Generic RFC1918 default suitable for a single-node research platform."
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vcn_cidr))
    error_message = "vcn_cidr must be a valid IPv4 CIDR block."
  }
}

variable "subnet_cidr" {
  type        = string
  description = "IPv4 CIDR block for the public compute subnet. Must be contained within vcn_cidr."
  default     = "10.0.1.0/24"

  validation {
    condition = (
      can(cidrnetmask(var.subnet_cidr)) &&
      can(cidrnetmask(var.vcn_cidr)) &&
      cidrcontains(var.vcn_cidr, cidrhost(var.subnet_cidr, 0)) &&
      cidrcontains(var.vcn_cidr, cidrhost(var.subnet_cidr, -1))
    )
    error_message = "subnet_cidr must be a valid IPv4 CIDR block fully contained within vcn_cidr."
  }
}

variable "ssh_ingress_cidr" {
  type        = string
  description = "IPv4 CIDR allowed to reach SSH (TCP/22) on instances attached to the compute NSG. Do not use 0.0.0.0/0 unless explicitly justified."

  validation {
    condition     = can(cidrnetmask(var.ssh_ingress_cidr))
    error_message = "ssh_ingress_cidr must be a valid IPv4 CIDR block."
  }
}

variable "vcn_dns_label" {
  type        = string
  description = "DNS label for the VCN (alphanumeric, starts with a letter, max 15 characters). Required for Internet and VCN Resolver support."
  default     = "tcvcn"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,14}$", var.vcn_dns_label))
    error_message = "vcn_dns_label must match ^[a-z][a-z0-9]{0,14}$."
  }
}

variable "subnet_dns_label" {
  type        = string
  description = "DNS label for the public subnet (alphanumeric, starts with a letter, max 15 characters)."
  default     = "compute"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{0,14}$", var.subnet_dns_label))
    error_message = "subnet_dns_label must match ^[a-z][a-z0-9]{0,14}$."
  }
}

variable "compute_ocpus" {
  type        = number
  description = "OCPU count for the OCI ARM reference profile (VM.Standard.A1.Flex). This is a sizing input, not a free-tier guarantee."
  default     = 4

  validation {
    condition     = var.compute_ocpus >= 1 && var.compute_ocpus <= 76
    error_message = "compute_ocpus must be between 1 and 76 for VM.Standard.A1.Flex."
  }
}

variable "compute_memory_gbs" {
  type        = number
  description = "Memory in GB for the OCI ARM reference profile (VM.Standard.A1.Flex). Per current OCI flexible-shape docs, minimum is max(1, OCPU count) and maximum is min(472, 64 * OCPUs). This is a sizing input, not a free-tier guarantee."
  default     = 24

  validation {
    # VM.Standard.A1.Flex flexible-shape limits from OCI Compute Shapes documentation:
    # minimum memory = max(1 GB, OCPU count); maximum = 64 GB per OCPU up to 472 GB.
    condition = (
      var.compute_memory_gbs >= max(1, var.compute_ocpus) &&
      var.compute_memory_gbs <= min(472, var.compute_ocpus * 64)
    )
    error_message = "compute_memory_gbs must satisfy VM.Standard.A1.Flex limits: at least max(1, compute_ocpus) GB and at most min(472, 64 * compute_ocpus) GB."
  }
}

variable "boot_volume_size_gbs" {
  type        = number
  description = "Boot volume size in GB for the compute instance. Counts toward combined boot and block volume capacity when assessing tenancy free-tier eligibility."
  default     = 50

  validation {
    condition     = var.boot_volume_size_gbs >= 50 && var.boot_volume_size_gbs <= 32768
    error_message = "boot_volume_size_gbs must be at least 50 GB."
  }
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key placed in instance metadata (authorized_keys). Private SSH keys must never be stored in Terraform configuration, committed tfvars, or GitHub Actions."

  validation {
    condition     = length(trimspace(var.ssh_public_key)) > 0
    error_message = "ssh_public_key must be a non-empty SSH public key string."
  }
}

variable "instance_hostname_label" {
  type        = string
  description = "Hostname label for the primary VNIC DNS name within the subnet."
  default     = "tcnode"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.instance_hostname_label))
    error_message = "instance_hostname_label must be a valid DNS hostname label."
  }
}

variable "compute_operating_system" {
  type        = string
  description = "Platform image operating system filter for the compute instance."
  default     = "Canonical Ubuntu"
}

variable "compute_operating_system_version" {
  type        = string
  description = "Platform image operating system version filter (Ubuntu 24.04 LTS)."
  default     = "24.04"
}
