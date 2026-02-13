# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "tenancy_ocid" {
  description = "OCID of the tenancy"
  type        = string
}

variable "compartment_ocid" {
  description = "Compartment OCID where OKE resources are created"
  type        = string
}

variable "vcn_id" {
  description = "VCN OCID used by OKE"
  type        = string
}

variable "subnet_id" {
  description = "Worker node subnet OCID"
  type        = string
}

variable "lb_subnet_id" {
  description = "Load balancer subnet OCID"
  type        = string
}

variable "cluster_name" {
  description = "OKE cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for OKE cluster"
  type        = string
}

variable "node_pool_name" {
  description = "Node pool name"
  type        = string
}

variable "node_pool_shape" {
  description = "Compute shape for node pool"
  type        = string
}

variable "node_pool_size" {
  description = "Number of worker nodes"
  type        = number
}

variable "cluster_options_add_ons_is_kubernetes_dashboard_enabled" {
  description = "Enable Kubernetes dashboard"
  type        = bool
}

variable "cluster_options_admission_controller_options_is_pod_security_policy_enabled" {
  description = "Enable Pod Security Policy"
  type        = bool
}

variable "nodepool_image_version" {
  description = "Node pool OS image version"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for worker nodes"
  type        = string
}

variable "create_new_oke_cluster" {
  description = "Whether to create a new OKE cluster"
  type        = bool
}

variable "existing_oke_cluster_id" {
  description = "Existing OKE cluster OCID (if not creating new)"
  type        = string
}

variable "cluster_endpoint_config_is_public_ip_enabled" {
  description = "Whether cluster API endpoint is public"
  type        = bool
}

variable "endpoint_subnet_id" {
  description = "Subnet OCID for cluster API endpoint"
  type        = string
}

variable "node_pool_node_shape_config_ocpus" {
  description = "OCPU count for flexible node shapes"
  type        = number
}

variable "node_pool_node_shape_config_memory_in_gbs" {
  description = "Memory in GB for flexible node shapes"
  type        = number
}

variable "is_flex_node_shape" {
  description = "Indicates if node shape is flexible"
  type        = bool
}

