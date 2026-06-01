# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
variable "region" {
  description = "OCI region."
  type        = string
}

variable "compartment_id" {
  description = "Compartment OCID where resources are created."
  type        = string
}

variable "tenancy_id" {
  description = "Tenancy OCID. Required only when create_iam_policy is true."
  type        = string
  default     = ""
}

variable "availability_domain" {
  description = "Availability domain name, for example Uocm:US-ASHBURN-AD-1."
  type        = string
}

variable "vcn_name" {
  description = "Existing VCN display name."
  type        = string
}

variable "container_subnet_name" {
  description = "Existing private subnet display name for the Container Instance backend."
  type        = string
}

variable "load_balancer_subnet_names" {
  description = "Comma-separated existing subnet display names for the public load balancer."
  type        = string
}

variable "app_name" {
  description = "Name prefix for deployed resources."
  type        = string
  default     = "oci-agent"
}

variable "shape" {
  description = "Container Instance shape."
  type        = string
  default     = "CI.Standard.A1.Flex"
}

variable "ocpus" {
  description = "OCPUs for flex shapes."
  type        = number
  default     = 1
}

variable "memory_in_gbs" {
  description = "Memory for flex shapes."
  type        = number
  default     = 8
}

variable "app_port" {
  description = "Application port."
  type        = number
  default     = 8000
}

variable "app_base_url" {
  description = "Public application URL. Required for OIDC auth. Use the HTTPS DNS name that points to the load balancer."
  type        = string
  default     = ""
}

variable "lb_min_bandwidth_mbps" {
  description = "Load balancer minimum bandwidth in Mbps."
  type        = number
  default     = 10
}

variable "lb_max_bandwidth_mbps" {
  description = "Load balancer maximum bandwidth in Mbps."
  type        = number
  default     = 10
}

variable "lb_certificate_name" {
  description = "Load balancer certificate name."
  type        = string
  default     = "oci-agent-cert"
}

variable "lb_certificate_public_pem" {
  description = "Public certificate PEM for HTTPS listener. Leave empty to deploy HTTP only."
  type        = string
  default     = ""
}

variable "lb_certificate_private_key_pem" {
  description = "Private key PEM for HTTPS listener. Leave empty to deploy HTTP only."
  type        = string
  default     = ""
  sensitive   = true
}

variable "lb_certificate_ca_pem" {
  description = "Optional CA/intermediate certificate chain PEM."
  type        = string
  default     = ""
}

variable "lb_certificate_public_pem_base64" {
  description = "Base64-encoded public certificate PEM. Preferred for Resource Manager forms."
  type        = string
  default     = ""
}

variable "lb_certificate_private_key_pem_base64" {
  description = "Base64-encoded private key PEM. Preferred for Resource Manager forms."
  type        = string
  default     = ""
  sensitive   = true
}

variable "lb_certificate_ca_pem_base64" {
  description = "Optional base64-encoded CA/intermediate certificate chain PEM."
  type        = string
  default     = ""
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

variable "container_platform" {
  description = "Container image build platform, for example linux/arm64 or linux/amd64."
  type        = string
  default     = "linux/arm64"
}

variable "docker_host" {
  description = "Docker-compatible socket used by the Terraform Docker provider. Defaults to the rootless Podman socket."
  type        = string
  default     = "unix:///run/user/1000/podman/podman.sock"
}

variable "container_image_override" {
  description = "Optional full image URL. Use this for non-OCIR registries or a fully custom image URL."
  type        = string
  default     = ""
}

variable "registry_username" {
  description = "Registry username. For OCIR, usually tenancy-namespace/oracle-identity-user."
  type        = string
  default     = ""
}

variable "registry_password" {
  description = "Registry password or auth token."
  type        = string
  default     = ""
  sensitive   = true
}

variable "oci_genai_project_id" {
  description = "OCI Generative AI project OCID."
  type        = string
}

variable "genai_compartment_id" {
  description = "Compartment OCID used by the app for Generative AI calls."
  type        = string
}

variable "model_id" {
  description = "Default model id."
  type        = string
  default     = "openai.gpt-oss-120b"
}

variable "create_iam_policy" {
  description = "Create a dynamic group and policy so the Container Instance resource principal can call OCI Generative AI."
  type        = bool
  default     = false
}

variable "auth_enabled" {
  description = "Enable OCI Identity Domain OIDC login."
  type        = bool
  default     = false
}

variable "identity_domain_issuer" {
  description = "OCI Identity Domain issuer URL. Required only when auth_enabled is true."
  type        = string
  default     = ""
}

variable "oidc_client_id" {
  description = "OIDC client id. Required only when auth_enabled is true."
  type        = string
  default     = ""
}

variable "oidc_client_secret" {
  description = "OIDC client secret. Required only when auth_enabled is true."
  type        = string
  default     = ""
  sensitive   = true
}
