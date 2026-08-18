# Terraform and provider version constraints for the OCI foundation.
# Strategy: pin the current minor line so patch updates are allowed, while
# preventing accidental jumps to the next minor or major release.

terraform {
  required_version = "~> 1.15.0"

  # Native OCI Object Storage remote state.
  # Location is supplied via partial backend configuration (backend.hcl).
  # The state bucket is an external prerequisite; Terraform does not create it.
  backend "oci" {}

  # Selected provider versions are recorded in the tracked
  # .terraform.lock.hcl. Do not hand-write provider hashes.
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.26.0"
    }
  }
}
