output "vcn_id" {
  description = "OCID of the TradingChassis VCN."
  value       = oci_core_vcn.this.id
}

output "subnet_id" {
  description = "OCID of the public compute subnet."
  value       = oci_core_subnet.public.id
}

output "compute_nsg_id" {
  description = "OCID of the compute Network Security Group."
  value       = oci_core_network_security_group.compute.id
}

output "instance_id" {
  description = "OCID of the reference compute instance."
  value       = oci_core_instance.node.id
}

output "instance_public_ip" {
  description = "Public IPv4 address of the reference compute instance for SSH access."
  value       = oci_core_instance.node.public_ip
}

output "instance_private_ip" {
  description = "Private IPv4 address of the reference compute instance."
  value       = oci_core_instance.node.private_ip
}

output "instance_availability_domain" {
  description = "Availability domain where the reference compute instance is placed."
  value       = oci_core_instance.node.availability_domain
}
