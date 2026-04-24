# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_core_shapes" "selected_shape" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  shape               = var.instance_shape
}

locals {
  selected_shape = data.oci_core_shapes.selected_shape.shapes[0]

  selected_shape_is_flexible = try(local.selected_shape.is_flexible, false)

  selected_shape_ocpu_min = try(local.selected_shape.ocpu_options[0].min, null)
  selected_shape_ocpu_max = try(local.selected_shape.ocpu_options[0].max, null)

  selected_shape_memory_min = try(local.selected_shape.memory_options[0].min_in_gbs, null)
  selected_shape_memory_max = try(local.selected_shape.memory_options[0].max_in_gbs, null)

  selected_shape_memory_per_ocpu_min = try(local.selected_shape.memory_options[0].min_per_ocpu_in_gbs, null)
  selected_shape_memory_per_ocpu_max = try(local.selected_shape.memory_options[0].max_per_ocpu_in_gbs, null)
}
