# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_identity_dynamic_group" "this" {
  compartment_id = var.tenancy_ocid
  name           = var.name
  description    = var.description
  matching_rule  = var.matching_rule
}