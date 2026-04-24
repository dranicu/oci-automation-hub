# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "compartment_ocid" {
  description = "OCI compartment OCID where the networking and compute instance will be created."
  type        = string
}

variable "availability_domain" {
  description = "Availability domain for the compute instance."
  type        = string
}

variable "image_id" {
  description = "OCI image OCID selected for the compute instance."
  type        = string
}

variable "instance_display_name" {
  description = "Display name for the OpenClaw compute instance."
  type        = string
  default     = "openclaw"
}

variable "instance_shape" {
  description = "OCI compute shape for the instance."
  type        = string
  default     = "VM.Standard.A1.Flex"
}

variable "instance_ocpus" {
  description = "Number of OCPUs for flexible compute shapes."
  type        = number
  default     = 2
}

variable "instance_memory_gbs" {
  description = "Memory in GBs for flexible compute shapes."
  type        = number
  default     = 12
}

variable "ssh_public_key" {
  description = "SSH public key to place on the instance."
  type        = string
}

variable "oci_genai_api_key" {
  description = "OCI Generative AI API key used for runtime chat-model discovery."
  type        = string
  sensitive   = true
}
