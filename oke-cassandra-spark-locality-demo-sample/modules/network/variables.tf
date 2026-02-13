# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

variable "compartment_ocid" {
  description = "OCID of the compartment where network resources will be created"
  type        = string
}

variable "VCN_CIDR" {
  description = "CIDR block for the VCN"
  type        = string
}

variable "vcn_dns_label" {
  description = "DNS label for the VCN"
  type        = string
}

variable "edge_cidr" {
  description = "CIDR block for the public (edge) subnet"
  type        = string
}

variable "private_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
}

variable "service_port" {
  description = "Application service port exposed on the edge subnet"
  type        = number
}
