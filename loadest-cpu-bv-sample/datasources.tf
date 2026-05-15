# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# =============================================================================
# Tenancy-level data sources used across the stack
# =============================================================================

# Fault domains — useful for spreading instances across FDs
data "oci_identity_fault_domains" "this" {
  count = length(data.oci_identity_availability_domains.this.availability_domains)

  availability_domain = data.oci_identity_availability_domains.this.availability_domains[count.index].name
  compartment_id      = var.compartment_ocid
}

# =============================================================================
# OCI Vault — retrieve SSH private key secret (if provided)
# =============================================================================
data "oci_secrets_secretbundle" "ssh_private_key" {
  count     = var.ssh_private_key_secret_ocid != "" ? 1 : 0
  secret_id = var.ssh_private_key_secret_ocid
}

# Image details — used to auto-detect the default OS login user (opc vs ubuntu)
data "oci_core_image" "instance_image" {
  image_id = var.instance_image_ocid
}

# Home region lookup — needed for Identity resources (dynamic groups, policies)
data "oci_identity_tenancy" "this" {
  tenancy_id = var.tenancy_ocid
}

data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
  filter {
    name   = "is_home_region"
    values = [true]
  }
}
