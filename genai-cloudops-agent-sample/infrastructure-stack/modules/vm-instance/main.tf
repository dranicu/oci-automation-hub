# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "oci_core_instance" "this" {
  for_each = var.instances

  availability_domain = each.value.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = each.value.display_name
  shape               = each.value.shape

  create_vnic_details {
    subnet_id        = each.value.subnet_id
    assign_public_ip = each.value.assign_public_ip
    hostname_label   = try(each.value.hostname_label, null)
  }

  dynamic "shape_config" {
    for_each = (try(each.value.ocpus, null) != null || try(each.value.memory_in_gbs, null) != null) ? [1] : []
    content {
      ocpus         = try(each.value.ocpus, null)
      memory_in_gbs = try(each.value.memory_in_gbs, null)
    }
  }

  source_details {
    source_type             = "image"
    source_id               = each.value.image_id
    boot_volume_size_in_gbs = try(each.value.boot_volume_size_in_gbs, null)
  }

  metadata = merge(
    length(try(each.value.ssh_public_keys, [])) > 0 ? {
      ssh_authorized_keys = join("\n", each.value.ssh_public_keys)
    } : {},
    try(each.value.user_data_base64, null) != null ? {
      user_data = each.value.user_data_base64
    } : {}
  )

  fault_domain = try(each.value.fault_domain, null)
}