# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "region" {
  description = "OCI region."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID for the Enterprise AI application."
  type        = string
}

variable "app_name" {
  description = "Enterprise AI application name."
  type        = string
  default     = "oci-agent"
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
  description = "Container image tag."
  type        = string
  default     = "latest"
}

variable "identity_domain_url" {
  description = "Identity domain URL for Enterprise AI application authentication."
  type        = string
}

variable "create_iam_confidential_app" {
  description = "Create an IAM Identity Domain confidential application for Enterprise AI authentication."
  type        = bool
  default     = false
}

variable "iam_confidential_app_name" {
  description = "Name for the IAM confidential application."
  type        = string
  default     = "oci-agent-enterprise-ai"
}

variable "iam_confidential_app_client_secret" {
  description = "Client secret for the IAM confidential application."
  type        = string
  default     = ""
  sensitive   = true
}

variable "identity_domain_scope" {
  description = "OAuth scope configured for agentic support."
  type        = string
  default     = "openid profile email"
}

variable "identity_domain_audience" {
  description = "OAuth audience from the identity domain integrated application."
  type        = string
  default     = ""
}

variable "oauth_scope_name" {
  description = "OAuth scope name exposed by the confidential app."
  type        = string
  default     = "agentic"
}

variable "min_replicas" {
  description = "Minimum hosted application replicas."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum hosted application replicas."
  type        = number
  default     = 3
}

variable "concurrency_target" {
  description = "Autoscaling concurrency target."
  type        = number
  default     = 25
}

variable "endpoint_type" {
  description = "Hosted application endpoint type."
  type        = string
  default     = "PUBLIC"
}
