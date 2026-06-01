# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
output "enterprise_ai_application_name" {
  description = "Application name to use in OCI Generative AI."
  value       = var.app_name
}

output "container_image" {
  description = "Container image to select for the Enterprise AI deployment artifact."
  value       = local.container_image
}

output "identity_domain_url" {
  description = "Identity domain URL to configure on the Enterprise AI application."
  value       = var.identity_domain_url
}

output "identity_domain_scope" {
  description = "OAuth scope to configure on the Enterprise AI application."
  value       = local.created_scope
}

output "identity_domain_audience" {
  description = "OAuth audience to configure on the Enterprise AI application."
  value       = local.created_audience
}

output "iam_confidential_app_id" {
  description = "IAM confidential app id when created by this stack."
  value       = var.create_iam_confidential_app ? oci_identity_domains_app.enterprise_ai[0].id : ""
}

output "iam_confidential_app_client_id" {
  description = "IAM confidential app client id/name when created by this stack."
  value       = var.create_iam_confidential_app ? oci_identity_domains_app.enterprise_ai[0].name : ""
}

output "scaling" {
  description = "Scaling values to configure on the hosted application."
  value       = "min=${var.min_replicas}, max=${var.max_replicas}, concurrency=${var.concurrency_target}"
}

output "endpoint_type" {
  description = "Endpoint type to configure on the hosted application."
  value       = var.endpoint_type
}

output "manual_steps" {
  description = "Current deployment steps for OCI Generative AI hosted applications."
  value = [
    "Create an OCI Generative AI Application in compartment ${var.compartment_id}.",
    "Set name to ${var.app_name}, replicas ${var.min_replicas}-${var.max_replicas}, endpoint type ${var.endpoint_type}.",
    "Configure authentication with identity domain ${var.identity_domain_url}, scope ${local.created_scope}, audience ${local.created_audience}.",
    "Create a Deployment for the application and select image ${local.container_image}.",
    "Activate the deployment and use the generated hosted application endpoint."
  ]
}
