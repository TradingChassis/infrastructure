# OCI provider configuration for static validation and future live use.
# Credentials are supplied by the execution environment during approved live
# operations and are never committed to this repository.
#
# Cloud Shell OCI CLI built-in auth (instance_obo_user / delegation_token) is
# NOT a Terraform provider auth mode. Canonical Cloud Shell workflow uses
# SecurityToken via oci session authenticate (see docs/V2_CLEAN_ROOM_DEPLOYMENT.md).
# Leave oci_auth / oci_config_file_profile unset for CI static validation.

provider "oci" {
  region              = var.oci_region
  auth                = var.oci_auth
  config_file_profile = var.oci_config_file_profile
}
