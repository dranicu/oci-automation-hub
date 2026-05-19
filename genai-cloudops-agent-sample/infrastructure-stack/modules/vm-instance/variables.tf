# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "compartment_ocid" {
  description = "OCI compartment OCID where the instances will be created."
  type        = string
}

variable "instances" {
  description = "Map of exactly two VM instances to create."
  type = map(object({
    display_name           = string
    availability_domain    = string
    shape                  = string
    image_id               = string
    subnet_id              = string
    assign_public_ip       = optional(bool, false)
    hostname_label         = optional(string)
    fault_domain           = optional(string)
    boot_volume_size_in_gbs = optional(number)
    ocpus                  = optional(number)
    memory_in_gbs          = optional(number)
    ssh_public_keys        = optional(list(string), [])
    user_data_base64       = optional(string)
  }))

  validation {
    condition     = length(var.instances) == 2
    error_message = "instances must contain exactly two entries."
  }
}