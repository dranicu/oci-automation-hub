# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "app_url" {
  description = "Application URL."
  value       = var.app_base_url != "" ? var.app_base_url : "http://${oci_load_balancer_load_balancer.app.ip_address_details[0].ip_address}"
}

output "configured_app_base_url" {
  description = "APP_BASE_URL configured inside the container."
  value       = var.app_base_url != "" ? var.app_base_url : "http://${oci_load_balancer_load_balancer.app.ip_address_details[0].ip_address}"
}

output "oidc_redirect_uri" {
  description = "Redirect URI to register in the OCI IAM confidential app."
  value       = "${var.app_base_url != "" ? var.app_base_url : "http://${oci_load_balancer_load_balancer.app.ip_address_details[0].ip_address}"}/auth/callback"
}

output "container_instance_id" {
  description = "Container Instance OCID."
  value       = oci_container_instances_container_instance.app.id
}

output "built_container_image" {
  description = "Container image URL built and pushed by the Resource Manager Docker provider."
  value       = local.container_image
}

output "load_balancer_public_ip" {
  description = "Public IP of the load balancer."
  value       = oci_load_balancer_load_balancer.app.ip_address_details[0].ip_address
}

output "container_private_ip" {
  description = "Private IP of the Container Instance backend."
  value       = data.oci_core_vnic.app.private_ip_address
}

output "selected_vcn_id" {
  description = "VCN OCID shared by the selected subnets."
  value       = local.selected_vcn.id
}

output "selected_vcn_cidr_blocks" {
  description = "CIDR blocks of the selected VCN."
  value       = local.selected_vcn.cidr_blocks
}

output "container_subnet_cidr_block" {
  description = "CIDR block of the selected container subnet."
  value       = local.selected_container_subnet.cidr_block
}

output "load_balancer_subnet_cidr_blocks" {
  description = "CIDR blocks of the selected load balancer subnets."
  value       = [for subnet in local.selected_load_balancer_subnets : subnet.cidr_block]
}
