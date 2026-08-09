# OCI scratch block storage for the V2 reference implementation.
#
# Terraform owns the cloud volume and attachment only.
# Ansible later owns safe device discovery, guarded filesystem creation, and
# persistent mounting. Argo CD later owns the Kubernetes storage contract.
#
# Host device names (for example /dev/oracleoci/oraclevds) are not treated as a
# stable infrastructure contract.

resource "oci_core_volume" "scratch" {
  compartment_id      = var.oci_compartment_id
  availability_domain = oci_core_instance.node.availability_domain
  display_name        = "${var.name_prefix}-scratch"
  size_in_gbs         = var.scratch_volume_size_gbs

  # Explicit Lower Cost performance tier for a cost-conscious reference profile.
  # See OCI Block Volume Performance Levels (0 = Lower Cost).
  vpus_per_gb = 0
}

resource "oci_core_volume_attachment" "scratch" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.node.id
  volume_id       = oci_core_volume.scratch.id
  display_name    = "${var.name_prefix}-scratch-attachment"

  # Single-instance read/write scratch attachment for the reference host.
  is_read_only  = false
  is_shareable  = false

  # In-transit encryption for paravirtualized attachments; platform encryption
  # at rest remains the OCI default without introducing a Vault/KMS resource.
  is_pv_encryption_in_transit_enabled = true
}
