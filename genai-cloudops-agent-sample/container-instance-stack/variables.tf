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

variable "availability_domain" {
  description = "Availability domain where the container instance will run."
  type        = string
}

variable "mcp_container_image_url" {
  description = "Container image URL, for example iad.ocir.io/namespace/repo:tag or docker.io/library/nginx:latest."
  type        = string
}

variable "app_container_image_url" {
  description = "Container image URL, for example iad.ocir.io/namespace/repo:tag or docker.io/library/nginx:latest."
  type        = string
}

variable "rag_agent_endpoint_id" {
  type = string
  description = "Agent Endpoint OCID for the RAG agent to connect to."
}

variable "shape" {
  description = "Container instance shape. Use a flexible shape supported by Container Instances."
  type        = string
  default     = "CI.Standard.E4.Flex"
}

variable "ocpus" {
  description = "Number of OCPUs to allocate to the container instance."
  type        = number
}

variable "memory_in_gbs" {
  description = "Amount of memory in GB to allocate to the container instance."
  type        = number
}

variable "mcpsubnet_id" {
  description = "Subnet OCID for the container instance VNIC."
  type        = string
}

variable "appsubnet_id" {
  description = "Subnet OCID for the application instance VNIC."
  type        = string
}

variable "appassign_public_ip" {
  description = "Assign Public IP to the application container"
  type = bool
  default = true
}

variable "oci_genai_endpoint" {
  description = "OCI GenAI endpoint URL for the RAG agent to connect to, for example https://genai.us-phoenix-1.oci.oraclecloud.com."
  type        = string
  default = "https://inference.generativeai.us-ashburn-1.oci.oraclecloud.com"
}

variable "oci_genai_model_id" {
  description = "OCI GenAI model ID for the RAG agent to use, for example 'gpt-4o'."
  type        = string
}

variable "mcpassign_public_ip" {
  description = "Whether to assign a public IP to the container instance VNIC."
  type        = bool
}