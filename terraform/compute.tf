# OCI Ampere ARM compute for the V2 reference implementation.
#
# Terraform owns the cloud compute instance only.
# Host bootstrap (MicroK8s, packages, mounts, firewall) remains Ansible later.
# Scratch block storage is deferred to the storage scope.
#
# Image selection uses the latest compatible Ubuntu 24.04 platform image for the
# A1 Flex shape. Platform images rotate; a newer image can force instance
# replacement on later plans unless the operator pins or ignores source changes.

locals {
  compute_shape = "VM.Standard.A1.Flex"
  compute_image = data.oci_core_images.ubuntu_arm64.images[0]
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.oci_compartment_id
}

data "oci_core_images" "ubuntu_arm64" {
  compartment_id           = var.oci_compartment_id
  operating_system         = var.compute_operating_system
  operating_system_version = var.compute_operating_system_version
  shape                    = local.compute_shape
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

resource "oci_core_instance" "node" {
  compartment_id      = var.oci_compartment_id
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[0].name
  display_name        = "${var.name_prefix}-node"
  shape               = local.compute_shape

  shape_config {
    ocpus         = var.compute_ocpus
    memory_in_gbs = var.compute_memory_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.public.id
    assign_public_ip = true
    hostname_label   = var.instance_hostname_label
    nsg_ids          = [oci_core_network_security_group.compute.id]
    display_name     = "${var.name_prefix}-node-vnic"
  }

  source_details {
    source_type             = "image"
    source_id               = local.compute_image.id
    boot_volume_size_in_gbs = var.boot_volume_size_gbs
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
  }
}
