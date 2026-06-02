# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

#############################
# OCI Provider Configuration
#############################

variable "region" {
  description = "OCI region where resources will be created."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCI tenancy OCID. Can be supplied via TF_VAR_tenancy_ocid or environment."
  type        = string
}

variable "compartment_ocid"{
    description = "OCI compartment OCID where resources will be created. Can be supplied via TF_VAR_compartment_ocid or environment."
    type        = string
}

variable "display_name_prefix" {
  description = "Prefix for all the components deployed by the stack."
  type = string
}

variable "component_description" {
  description = "Description for the components deployed by the stack."
  type = string
}

#############################
# Test Instance Configuration
#############################
variable "availability_domain" {
  description = "Availability domain for the test instances."
  type = string
}

variable "instance_shape" {
  description = "Shape for the test instances."
  type = string
}

variable "image_id" {
  description = "Image ID for the test instances."
  type = string
}

variable "subnet_id" {
  description = "Subnet ID for the test instances."
  type = string
}

variable "ssh_public_keys" {
  description = "List of SSH public keys for the test instances."
}

#############################
# Tagging (Optional)
#############################

variable "tags" {
  description = "Defined and freeform tags for resources."
  type = object({
    definedTags  = optional(map(string))
    freeformTags = optional(map(string))
  })
  default = {}
}