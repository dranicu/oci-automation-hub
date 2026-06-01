# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "random_password" "session_secret" {
  length  = 48
  special = false
}

resource "oci_core_vcn" "app" {
  compartment_id = var.compartment_id
  cidr_block     = "10.42.0.0/16"
  display_name   = "${var.app_name}-vcn"
  dns_label      = "ociagent"
}

resource "oci_core_internet_gateway" "app" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.app.id
  display_name   = "${var.app_name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.app.id
  display_name   = "${var.app_name}-public-rt"

  route_rules {
    network_entity_id = oci_core_internet_gateway.app.id
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
  }
}

resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_id
  vcn_id         = oci_core_vcn.app.id
  display_name   = "${var.app_name}-public-sl"

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = oci_core_vcn.app.cidr_block

    tcp_options {
      min = var.app_port
      max = var.app_port
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_id
  vcn_id                     = oci_core_vcn.app.id
  cidr_block                 = "10.42.1.0/24"
  display_name               = "${var.app_name}-public-subnet"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false
}

resource "oci_identity_dynamic_group" "app" {
  count          = var.create_iam_policy ? 1 : 0
  compartment_id = var.tenancy_id
  name           = "${var.app_name}-container-instance-rp"
  description    = "Resource principal dynamic group for ${var.app_name} Container Instances."
  matching_rule  = "ALL {resource.type = 'computecontainerinstance', resource.compartment.id = '${var.compartment_id}'}"
}

resource "oci_identity_policy" "genai" {
  count          = var.create_iam_policy ? 1 : 0
  compartment_id = var.tenancy_id
  name           = "${var.app_name}-genai-policy"
  description    = "Allow ${var.app_name} Container Instances to call OCI Generative AI."
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.app[0].name} to use generative-ai-family in compartment id ${var.genai_compartment_id}"
  ]
}

locals {
  computed_container_image = "${lower(var.ocir_region_key)}.ocir.io/${var.ocir_namespace}/${var.image_repository}:${var.image_tag}"
  container_image          = var.container_image_override != "" ? var.container_image_override : local.computed_container_image
  registry_endpoint        = split("/", local.container_image)[0]
  app_base_url             = var.app_base_url != "" ? var.app_base_url : "http://localhost:${var.app_port}"
  https_enabled            = var.lb_certificate_public_pem != "" && var.lb_certificate_private_key_pem != ""

  app_environment = {
    PORT                           = tostring(var.app_port)
    LOG_LEVEL                      = "INFO"
    APP_BASE_URL                   = local.app_base_url
    APP_DATA_DIR                   = "/app/data"
    AUTH_ENABLED                   = tostring(var.auth_enabled)
    APP_SESSION_SECRET             = random_password.session_secret.result
    AUTH_COOKIE_SECURE             = startswith(local.app_base_url, "https://") ? "true" : "false"
    OCI_REGION                     = var.region
    OCI_GENAI_AUTH_MODE            = "RESOURCE_PRINCIPAL"
    OCI_GENAI_PROJECT_ID           = var.oci_genai_project_id
    COMPARTMENT_ID                 = var.genai_compartment_id
    MODEL_ID                       = var.model_id
    OCI_IDENTITY_DOMAIN_ISSUER     = var.identity_domain_issuer
    OCI_OIDC_CLIENT_ID             = var.oidc_client_id
    OCI_OIDC_CLIENT_SECRET         = var.oidc_client_secret
    OCI_OIDC_REDIRECT_URI          = "${local.app_base_url}/auth/callback"
    APP_TLS_CERT_FILE              = ""
    APP_TLS_KEY_FILE               = ""
    OCI_GENAI_MEMORY_SUBJECT_ID    = ""
    OCI_GENAI_MEMORY_ACCESS_POLICY = "recall_and_store"
  }
}

resource "oci_container_instances_container_instance" "app" {
  availability_domain      = var.availability_domain
  compartment_id           = var.compartment_id
  container_restart_policy = "ALWAYS"
  display_name             = "${var.app_name}-container-instance"
  shape                    = var.shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_in_gbs
  }

  containers {
    display_name                   = var.app_name
    image_url                      = local.container_image
    environment_variables          = local.app_environment
    is_resource_principal_disabled = false

    resource_config {
      memory_limit_in_gbs = var.memory_in_gbs
      vcpus_limit         = var.ocpus
    }

    health_checks {
      health_check_type        = "HTTP"
      name                     = "healthz"
      path                     = "/healthz"
      port                     = var.app_port
      initial_delay_in_seconds = 30
      interval_in_seconds      = 30
      timeout_in_seconds       = 5
      failure_threshold        = 3
      success_threshold        = 1
      failure_action           = "KILL"
    }

    volume_mounts {
      mount_path   = "/app/data"
      volume_name  = "app-data"
      is_read_only = false
    }
  }

  dynamic "image_pull_secrets" {
    for_each = var.registry_username != "" && var.registry_password != "" ? [1] : []
    content {
      registry_endpoint = local.registry_endpoint
      secret_type       = "BASIC"
      username          = base64encode(var.registry_username)
      password          = base64encode(var.registry_password)
    }
  }

  vnics {
    display_name          = "${var.app_name}-vnic"
    subnet_id             = oci_core_subnet.public.id
    is_public_ip_assigned = false
  }

  volumes {
    name          = "app-data"
    volume_type   = "EMPTYDIR"
    backing_store = "EPHEMERAL_STORAGE"
  }

  lifecycle {
    precondition {
      condition     = !var.auth_enabled || var.app_base_url != ""
      error_message = "app_base_url is required when auth_enabled is true. Use the same base URL in the OCI IAM confidential app."
    }

    precondition {
      condition     = !var.auth_enabled || startswith(var.app_base_url, "https://")
      error_message = "app_base_url must start with https:// when auth_enabled is true."
    }
  }
}

data "oci_core_vnic" "app" {
  vnic_id = oci_container_instances_container_instance.app.vnics[0].vnic_id
}

resource "oci_load_balancer_load_balancer" "app" {
  compartment_id = var.compartment_id
  display_name   = "${var.app_name}-lb"
  shape          = "flexible"
  subnet_ids     = [oci_core_subnet.public.id]
  is_private     = false

  shape_details {
    minimum_bandwidth_in_mbps = var.lb_min_bandwidth_mbps
    maximum_bandwidth_in_mbps = var.lb_max_bandwidth_mbps
  }
}

resource "oci_load_balancer_backend_set" "app" {
  load_balancer_id = oci_load_balancer_load_balancer.app.id
  name             = "${var.app_name}-backend-set"
  policy           = "ROUND_ROBIN"

  health_checker {
    protocol          = "HTTP"
    port              = var.app_port
    url_path          = "/healthz"
    return_code       = 200
    retries           = 3
    timeout_in_millis = 5000
    interval_ms       = 30000
  }
}

resource "oci_load_balancer_backend" "app" {
  load_balancer_id = oci_load_balancer_load_balancer.app.id
  backendset_name  = oci_load_balancer_backend_set.app.name
  ip_address       = data.oci_core_vnic.app.private_ip_address
  port             = var.app_port
}

resource "oci_load_balancer_listener" "http" {
  load_balancer_id         = oci_load_balancer_load_balancer.app.id
  name                     = "${var.app_name}-http"
  default_backend_set_name = oci_load_balancer_backend_set.app.name
  port                     = 80
  protocol                 = "HTTP"
}

resource "oci_load_balancer_certificate" "https" {
  count              = local.https_enabled ? 1 : 0
  load_balancer_id   = oci_load_balancer_load_balancer.app.id
  certificate_name   = var.lb_certificate_name
  public_certificate = var.lb_certificate_public_pem
  private_key        = var.lb_certificate_private_key_pem
  ca_certificate     = var.lb_certificate_ca_pem
}

resource "oci_load_balancer_listener" "https" {
  count                    = local.https_enabled ? 1 : 0
  load_balancer_id         = oci_load_balancer_load_balancer.app.id
  name                     = "${var.app_name}-https"
  default_backend_set_name = oci_load_balancer_backend_set.app.name
  port                     = 443
  protocol                 = "HTTP"

  ssl_configuration {
    certificate_name        = oci_load_balancer_certificate.https[0].certificate_name
    verify_peer_certificate = false
  }
}
