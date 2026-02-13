# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "availability_domain" {
  description = "Availability Domain index used for bastion instance"
  type        = string
  default     = "0"
}

variable "compartment_ocid" {
  description = "Compartment OCID where bastion will be created"
  type        = string
}

variable "subnet_id" {
  description = "Subnet OCID where bastion will be deployed"
  type        = string
}

variable "instance_name" {
  description = "Display name of bastion instance"
  type        = string
}

variable "instance_shape" {
  description = "Compute shape for bastion instance"
  type        = string
}

variable "image_id" {
  description = "Image OCID used for bastion instance"
  type        = string
}

variable "public_edge_node" {
  description = "Whether bastion should have public IP"
  type        = bool
}

variable "ssh_public_key" {
  description = "SSH public key injected into bastion"
  type        = string
}

variable "oke_cluster_id" {
  description = "OKE cluster OCID"
  type        = string
}

variable "nodepool_id" {
  description = "OKE node pool OCID"
  type        = string
}

variable "user_data" {
  description = "Cloud-init script for bastion"
  type        = string
}

variable "bastion_shape_config_ocpus" {
  description = "OCPU count for flexible bastion shapes"
  type        = string
}

variable "bastion_shape_config_memory_in_gbs" {
  description = "Memory size in GB for flexible bastion shapes"
  type        = string
}

variable "is_flex_bastion_shape" {
  description = "Indicates if bastion shape is flexible"
  type        = bool
}