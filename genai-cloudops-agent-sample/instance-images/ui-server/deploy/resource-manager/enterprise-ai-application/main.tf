# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  container_image   = "${lower(var.ocir_region_key)}.ocir.io/${var.ocir_namespace}/${var.image_repository}:${var.image_tag}"
  confidential_name = lower(replace(var.iam_confidential_app_name, " ", "-"))
  created_audience  = var.create_iam_confidential_app ? "https://${local.confidential_name}" : var.identity_domain_audience
  created_scope     = var.create_iam_confidential_app ? "${local.created_audience}/${var.oauth_scope_name}" : var.identity_domain_scope
  note              = "OCI Generative AI hosted Applications and Deployments are documented as console/API resources. This stack can create the IAM confidential app, then outputs the values to use when creating the hosted application and deployment."
}

resource "oci_identity_domains_app" "enterprise_ai" {
  count         = var.create_iam_confidential_app ? 1 : 0
  display_name  = var.iam_confidential_app_name
  idcs_endpoint = var.identity_domain_url
  name          = local.confidential_name

  based_on_template {
    value         = "CustomWebAppTemplateId"
    well_known_id = "CustomWebAppTemplateId"
  }

  active            = true
  client_type       = "confidential"
  is_oauth_client   = true
  is_oauth_resource = true
  login_mechanism   = "OIDC"
  allowed_grants    = ["client_credentials"]
  client_secret     = var.iam_confidential_app_client_secret != "" ? var.iam_confidential_app_client_secret : null

  scopes {
    value                = var.oauth_scope_name
    description          = "Scope for OCI Enterprise AI application agentic access."
    requires_consent     = false
    fqs                  = local.created_scope
    available_to_clients = true
  }
}
