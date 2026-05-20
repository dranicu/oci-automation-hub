# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# =============================================================================
# Availability Domain Data Source
# =============================================================================
data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

# =============================================================================
# Cloud-init version tracker
#
# cloud-init only runs on an instance's first boot, and `user_data` is an
# updatable attribute — so editing the cloud-init script merely updates instance
# metadata in place and the new script never runs. This resource hashes the
# cloud-init content; oci_core_instance references it in replace_triggered_by so
# the instance is recreated whenever the script changes.
# =============================================================================
resource "null_resource" "cloud_init_version" {
  triggers = {
    cloud_init = local.has_cloud_init ? md5(local.cloud_init_multipart) : "none"
  }
}

# =============================================================================
# Compute Instances
# =============================================================================
resource "oci_core_instance" "this" {
  count = var.instance_count

  compartment_id      = var.compartment_ocid
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[count.index % length(data.oci_identity_availability_domains.this.availability_domains)].name
  shape               = var.instance_shape
  display_name        = "${var.resource_name_prefix}-vm-${count.index + 1}"
  freeform_tags       = merge(local.common_tags, { "InstanceIndex" = tostring(count.index + 1) })

  # Flex shape configuration
  dynamic "shape_config" {
    for_each = local.is_flex_shape ? [1] : []
    content {
      ocpus         = var.instance_flex_ocpus
      memory_in_gbs = var.instance_flex_memory_in_gbs
    }
  }

  # Source image
  source_details {
    source_type             = "image"
    source_id               = var.instance_image_ocid
    boot_volume_size_in_gbs = var.instance_boot_volume_size_in_gbs
  }

  # Network
  create_vnic_details {
    subnet_id                 = oci_core_subnet.compute.id
    assign_public_ip          = var.subnet_is_public ? var.assign_public_ip : false
    display_name              = "${var.resource_name_prefix}-vnic-${count.index + 1}"
    hostname_label            = "${var.resource_name_prefix}-vm-${count.index + 1}"
    nsg_ids                   = [oci_core_network_security_group.compute.id]
    assign_ipv6ip             = false
    skip_source_dest_check    = false
  }

  # Metadata
  metadata = {
    ssh_authorized_keys = var.ssh_public_key
    user_data           = local.has_cloud_init ? base64encode(local.cloud_init_multipart) : null
  }

  # Instance options
  instance_options {
    are_legacy_imds_endpoints_disabled = true # Enforce IMDSv2
  }

  agent_config {
    is_monitoring_disabled  = false
    is_management_disabled  = false
    are_all_plugins_disabled = false

    plugins_config {
      name          = "Vulnerability Scanning"
      desired_state = "ENABLED"
    }

    plugins_config {
      name          = "OS Management Service Agent"
      desired_state = "ENABLED"
    }

    plugins_config {
      name          = "Bastion"
      desired_state = "ENABLED"
    }
  }

  # Recreate the instance whenever the cloud-init content changes, so script
  # edits actually take effect (cloud-init runs only on first boot).
  lifecycle {
    replace_triggered_by  = [null_resource.cloud_init_version]
    create_before_destroy = false
  }
}
