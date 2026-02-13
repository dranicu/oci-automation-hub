# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "vcn_id" {
  value = oci_core_vcn.dl_vcn.id
}

output "private_id" {
  value = oci_core_subnet.private.id
}

output "edge_id" {
  value = oci_core_subnet.edge.id
}