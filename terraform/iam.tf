# OCI instance principal access for Vault secret-bundle reads.
#
# Terraform owns Dynamic Group membership and the least-privilege IAM policy.
# The Vault and secret values remain externally managed.
# Secrets Store CSI, SecretProviderClass, and Argo CD runtime injection remain
# later Ansible / Argo CD migration concerns.

resource "oci_identity_dynamic_group" "instance_principal" {
  compartment_id = var.oci_tenancy_id
  name           = "${var.name_prefix}-instance-principal"
  description    = "Dynamic group for the TradingChassis reference compute instance principal."

  # Match only the Terraform-managed reference instance.
  matching_rule = "All {instance.id = '${oci_core_instance.node.id}'}"
}

resource "oci_identity_policy" "vault_secret_bundles" {
  compartment_id = var.oci_tenancy_id
  name           = "${var.name_prefix}-vault-secret-bundles"
  description    = "Allow the reference instance principal to read OCI Vault secret bundles in the configured secret compartment."

  statements = [
    "Allow dynamic-group id ${oci_identity_dynamic_group.instance_principal.id} to read secret-bundles in compartment id ${var.oci_vault_compartment_id}",
  ]
}
