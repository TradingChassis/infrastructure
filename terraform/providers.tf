# OCI provider configuration for static validation and future live use.
# Credentials are supplied by the execution environment during approved live
# operations and are never committed to this repository.

provider "oci" {
  region = var.oci_region
}
