variable "oci_region" {
  type        = string
  description = "OCI region used by the Terraform OCI provider (for example eu-frankfurt-1)."
}

variable "oci_compartment_id" {
  type        = string
  description = "OCID of the compartment that owns the OCI network resources."
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
    condition     = can(cidrnetmask(var.subnet_cidr))
    error_message = "subnet_cidr must be a valid IPv4 CIDR block."
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
