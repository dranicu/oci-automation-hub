# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "oci_provider" {
  type = map(string)
}

variable "bucket_params" {
  type = map(object({
    compartment_name = string
    name             = string
    access_type      = string
    storage_tier     = string
    events_enabled   = bool
    kms_key_name     = string
    force_destroy    = optional(bool, false)
  }))
}

variable "compartments" {
  type = map(string)
}

variable "kms_key_ids" {
  type = map(string)
}
