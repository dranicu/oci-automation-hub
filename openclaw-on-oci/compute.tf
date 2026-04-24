# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

data "oci_core_image" "selected_image" {
  image_id = var.image_id
}

data "oci_core_images" "compatible_ol9_images" {
  compartment_id           = var.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "9"
  shape                    = var.instance_shape
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

locals {
  compatible_image_ids = [for image in data.oci_core_images.compatible_ol9_images.images : image.id]
}

resource "oci_core_instance" "openclaw" {
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = var.instance_display_name
  shape               = var.instance_shape

  shape_config {
    ocpus         = var.instance_ocpus
    memory_in_gbs = var.instance_memory_gbs
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.openclaw_public.id
    assign_public_ip = true
  }

  source_details {
    source_type = "image"
    source_id   = var.image_id
  }

  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = base64encode(local.openclaw_cloud_init_user_data)
  }

  lifecycle {
    precondition {
      condition     = local.selected_shape_is_flexible
      error_message = "The selected shape must be a flexible shape."
    }

    precondition {
      condition     = data.oci_core_image.selected_image.operating_system == "Oracle Linux"
      error_message = "The selected image must be an Oracle Linux image."
    }

    precondition {
      condition     = tostring(data.oci_core_image.selected_image.operating_system_version) == "9"
      error_message = "The selected image must be an Oracle Linux 9 image."
    }

    precondition {
      condition     = contains(local.compatible_image_ids, var.image_id)
      error_message = "The selected image is not compatible with the selected shape."
    }

    precondition {
      condition = (
        local.selected_shape_ocpu_min == null ||
        local.selected_shape_ocpu_max == null ||
        (
          var.instance_ocpus >= local.selected_shape_ocpu_min &&
          var.instance_ocpus <= local.selected_shape_ocpu_max
        )
      )
      error_message = "The selected OCPU value is outside the supported range for the chosen shape."
    }

    precondition {
      condition = (
        local.selected_shape_memory_min == null ||
        local.selected_shape_memory_max == null ||
        (
          var.instance_memory_gbs >= local.selected_shape_memory_min &&
          var.instance_memory_gbs <= local.selected_shape_memory_max
        )
      )
      error_message = "The selected memory value is outside the supported total memory range for the chosen shape."
    }

    precondition {
      condition = (
        local.selected_shape_memory_per_ocpu_min == null ||
        local.selected_shape_memory_per_ocpu_max == null ||
        (
          (var.instance_memory_gbs / var.instance_ocpus) >= local.selected_shape_memory_per_ocpu_min &&
          (var.instance_memory_gbs / var.instance_ocpus) <= local.selected_shape_memory_per_ocpu_max
        )
      )
      error_message = "The selected memory-to-OCPU ratio is outside the supported per-OCPU memory range for the chosen shape."
    }
  }
}
