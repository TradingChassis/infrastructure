output "vcn_id" {
  description = "OCID of the TradingChassis VCN."
  value       = oci_core_vcn.this.id
}

output "subnet_id" {
  description = "OCID of the public compute subnet for later instance attachment."
  value       = oci_core_subnet.public.id
}

output "compute_nsg_id" {
  description = "OCID of the compute Network Security Group for later instance attachment."
  value       = oci_core_network_security_group.compute.id
}
