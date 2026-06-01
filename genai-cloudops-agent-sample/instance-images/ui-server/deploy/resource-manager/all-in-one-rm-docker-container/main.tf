# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
resource "random_password" "session_secret" {
  length  = 48
  special = false
}

data "oci_core_vcns" "selected" {
  compartment_id = var.compartment_id
  display_name   = var.vcn_name
}

locals {
  selected_vcns = data.oci_core_vcns.selected.virtual_networks
  selected_vcn  = local.selected_vcns[0]
}

data "oci_core_subnets" "container" {
  compartment_id = var.compartment_id
  vcn_id         = local.selected_vcn.id
  display_name   = var.container_subnet_name
}

data "oci_core_subnets" "load_balancer" {
  count          = length(local.load_balancer_subnet_names)
  compartment_id = var.compartment_id
  vcn_id         = local.selected_vcn.id
  display_name   = local.load_balancer_subnet_names[count.index]
}

locals {
  load_balancer_subnet_names     = [for name in split(",", var.load_balancer_subnet_names) : trimspace(name) if trimspace(name) != ""]
  selected_container_subnets     = data.oci_core_subnets.container.subnets
  selected_container_subnet      = local.selected_container_subnets[0]
  selected_load_balancer_subnets = [for item in data.oci_core_subnets.load_balancer : item.subnets[0]]

  source_files = [
    for file in fileset("${path.module}/source", "**") : file
    if !startswith(file, ".git/")
    && !startswith(file, "data/")
    && !startswith(file, "certs/")
    && file != ".env"
  ]
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

  lb_public_certificate_input = trimspace(var.lb_certificate_public_pem_base64) != "" ? trimspace(var.lb_certificate_public_pem_base64) : trimspace(var.lb_certificate_public_pem)
  lb_private_key_input        = trimspace(var.lb_certificate_private_key_pem_base64) != "" ? trimspace(var.lb_certificate_private_key_pem_base64) : trimspace(var.lb_certificate_private_key_pem)
  lb_ca_certificate_input     = trimspace(var.lb_certificate_ca_pem_base64) != "" ? trimspace(var.lb_certificate_ca_pem_base64) : trimspace(var.lb_certificate_ca_pem)

  lb_public_certificate = local.lb_public_certificate_input == "" ? "" : (
    can(base64decode(local.lb_public_certificate_input)) && !startswith(local.lb_public_certificate_input, "-----BEGIN")
    ? base64decode(local.lb_public_certificate_input)
    : replace(local.lb_public_certificate_input, "\\n", "\n")
  )
  lb_private_key = local.lb_private_key_input == "" ? "" : (
    can(base64decode(local.lb_private_key_input)) && !startswith(local.lb_private_key_input, "-----BEGIN")
    ? base64decode(local.lb_private_key_input)
    : replace(local.lb_private_key_input, "\\n", "\n")
  )
  lb_ca_certificate = local.lb_ca_certificate_input == "" ? "" : (
    can(base64decode(local.lb_ca_certificate_input)) && !startswith(local.lb_ca_certificate_input, "-----BEGIN")
    ? base64decode(local.lb_ca_certificate_input)
    : replace(local.lb_ca_certificate_input, "\\n", "\n")
  )
  https_enabled = local.lb_public_certificate != "" && local.lb_private_key != ""

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

resource "oci_artifacts_container_repository" "app" {
  compartment_id = var.compartment_id
  display_name   = var.image_repository
  is_public      = false
}

resource "docker_image" "app" {
  name         = local.container_image
  keep_locally = true

  build {
    context    = "${path.module}/source"
    dockerfile = "Dockerfile"
    platform   = var.container_platform
    tag        = [local.container_image]
  }

  triggers = {
    source_hash = sha256(join("", [for file in local.source_files : filesha256("${path.module}/source/${file}")]))
  }

  depends_on = [oci_artifacts_container_repository.app]
}

resource "docker_registry_image" "app" {
  name          = docker_image.app.name
  keep_remotely = true

  auth_config {
    address  = "${lower(var.ocir_region_key)}.ocir.io"
    username = var.registry_username
    password = var.registry_password
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
    subnet_id             = local.selected_container_subnet.id
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

    precondition {
      condition     = length(local.selected_vcns) == 1
      error_message = "vcn_name must match exactly one VCN in the selected compartment."
    }

    precondition {
      condition     = length(local.selected_container_subnets) == 1
      error_message = "container_subnet_name must match exactly one subnet in the selected VCN."
    }

    precondition {
      condition     = length(local.load_balancer_subnet_names) > 0 && alltrue([for item in data.oci_core_subnets.load_balancer : length(item.subnets) == 1])
      error_message = "Each load_balancer_subnet_names value must match exactly one subnet in the selected VCN."
    }
  }

  depends_on = [docker_registry_image.app]
}

data "oci_core_vnic" "app" {
  vnic_id = oci_container_instances_container_instance.app.vnics[0].vnic_id
}

resource "oci_load_balancer_load_balancer" "app" {
  compartment_id = var.compartment_id
  display_name   = "${var.app_name}-lb"
  shape          = "flexible"
  subnet_ids     = [for subnet in local.selected_load_balancer_subnets : subnet.id]
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
  public_certificate = local.lb_public_certificate
  private_key        = local.lb_private_key
  ca_certificate     = local.lb_ca_certificate
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
