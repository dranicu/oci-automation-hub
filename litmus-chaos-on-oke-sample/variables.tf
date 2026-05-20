# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

#p rovider
variable "tenancy_ocid" {
}

variable "compartment_ocid" {
}

variable "region" {
}

# vcn

variable "cidr_blocks" {
  type = any
}

variable "vcn_display_name" {
  type = string
}

# subnets
variable "api_endpoint_subnet_cidr" {
  type = string
}

variable "lb_subnet_cidr" {
  type = string
}

variable "nodepool_subnet_cidr" {
  type = string
}

variable "pods_subnet_cidr" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "kubernetes_version"{
  type = string
}

variable "litmus_namespace" {
  description = "Namespace for Litmus deployment"
  type        = string
  default     = "litmus"
}

variable "litmus_chart_version" {
  description = "Litmus Helm chart version"
  type        = string
  default     = "3.27.0"
}

variable "litmus_service_type" {
  description = "Litmus portal service type"
  type        = string
  default     = "LoadBalancer"
}

variable "litmus_frontend_service_name" {
  description = "Kubernetes Service name for the Litmus portal frontend"
  type        = string
  default     = "litmus-frontend-service"
}