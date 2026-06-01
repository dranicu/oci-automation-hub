# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "oci_region" {
  description = "OCI region name used by the OCI provider when creating the OCIR repository, for example us-ashburn-1."
  type        = string
  default     = "us-ashburn-1"
}

variable "ocir_region_key" {
  description = "OCIR region key, for example iad, phx, bom, hyd, fra, lhr."
  type        = string
  default     = "iad"
}

variable "ocir_namespace" {
  description = "OCIR tenancy namespace."
  type        = string
}

variable "image_repository" {
  description = "OCIR repository name."
  type        = string
  default     = "oci-agent"
}

variable "image_tag" {
  description = "Image tag."
  type        = string
  default     = "latest"
}

variable "registry_username" {
  description = "OCIR username, usually namespace/user@example.com."
  type        = string
}

variable "registry_auth_token" {
  description = "OCI auth token used for docker login."
  type        = string
  sensitive   = true
}

variable "create_repository" {
  description = "Create the OCIR repository with the OCI Terraform provider before pushing."
  type        = bool
  default     = false
}

variable "repository_compartment_id" {
  description = "Compartment OCID for OCIR repository creation. Required when create_repository is true."
  type        = string
  default     = ""
}

variable "platform" {
  description = "Optional Docker build platform, for example linux/arm64 or linux/amd64."
  type        = string
  default     = "linux/arm64"
}

variable "source_dir" {
  description = "Source directory containing the Dockerfile."
  type        = string
  default     = "../.."
}
