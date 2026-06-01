# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "container_image" {
  description = "Full pushed image URL."
  value       = local.image_url
}

output "resource_manager_image_values" {
  description = "Values to enter in the Resource Manager deployment stack."
  value = {
    ocir_region_key  = var.ocir_region_key
    ocir_namespace   = var.ocir_namespace
    image_repository = var.image_repository
    image_tag        = var.image_tag
  }
}
