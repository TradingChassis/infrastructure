# Terraform and provider version constraints for the OCI foundation.
# Strategy: pin the current minor line so patch updates are allowed, while
# preventing accidental jumps to the next minor or major release.

terraform {
  required_version = "~> 1.15.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.26.0"
    }
  }
}
