# OCI network foundation for the V2 reference implementation.
#
# Ownership:
# - Terraform owns cloud network resources and instance-oriented NSG policy.
# - Host firewall policy remains a separate Ansible concern.
# - Application NodePort exposure is deferred; this scope allows SSH ingress only.
#
# The VCN still creates a default security list. This configuration attaches an
# intentionally empty security list to the subnet so instance access policy is
# owned by the compute NSG instead of the permissive VCN default list.

locals {
  name_prefix = var.name_prefix
}

resource "oci_core_vcn" "this" {
  compartment_id = var.oci_compartment_id
  display_name   = "${local.name_prefix}-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = var.vcn_dns_label
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.oci_compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name_prefix}-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.oci_compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name_prefix}-public-rt"

  route_rules {
    description       = "Default route to the internet gateway for public subnet egress."
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

# Empty on purpose: subnet association only. Do not place instance access rules here.
resource "oci_core_security_list" "subnet_baseline" {
  compartment_id = var.oci_compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name_prefix}-subnet-baseline-sl"
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.oci_compartment_id
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "${local.name_prefix}-subnet"
  dns_label                  = var.subnet_dns_label
  cidr_block                 = var.subnet_cidr
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.subnet_baseline.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_network_security_group" "compute" {
  compartment_id = var.oci_compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name_prefix}-compute-nsg"
}

resource "oci_core_network_security_group_security_rule" "ssh_ingress" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "INGRESS"
  protocol                  = "6"
  description               = "Allow SSH from the configured operator CIDR only."
  source                    = var.ssh_ingress_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.compute.id
  direction                 = "EGRESS"
  protocol                  = "all"
  description               = "Broad outbound internet access is an explicit bootstrap/runtime requirement, not an implicit default."
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  stateless                 = false
}
