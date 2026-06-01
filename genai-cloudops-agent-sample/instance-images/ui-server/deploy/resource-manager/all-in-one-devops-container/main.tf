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

resource "oci_devops_project" "app" {
  compartment_id = var.compartment_id
  name           = "${var.app_name}-devops"
  description    = "Build project for ${var.app_name}."

  notification_config {
    topic_id = var.notification_topic_id
  }
}

resource "oci_artifacts_container_repository" "app" {
  compartment_id = var.compartment_id
  display_name   = var.image_repository
  is_public      = false
}

resource "oci_devops_repository" "source" {
  count           = var.create_hosted_source_repository ? 1 : 0
  name            = var.hosted_source_repository_name
  project_id      = oci_devops_project.app.id
  repository_type = "HOSTED"
  default_branch  = var.source_repository_branch
  description     = "Bundled source repository for ${var.app_name}."
}

resource "terraform_data" "push_source" {
  count = var.create_hosted_source_repository ? 1 : 0

  triggers_replace = {
    repository_url = oci_devops_repository.source[0].http_url
    source_hash    = sha256(join("", [for file in fileset("${path.module}/source", "**") : filesha256("${path.module}/source/${file}")]))
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/source"
    command     = <<-EOT
      set -eu
      git init
      git checkout -B "${var.source_repository_branch}"
      git add .
      git -c user.name="Resource Manager" -c user.email="resource-manager@example.invalid" commit -m "Initial source import" || true
      git remote remove origin 2>/dev/null || true
      git remote add origin "${oci_devops_repository.source[0].http_url}"
      git push -u origin "${var.source_repository_branch}" --force
    EOT

    environment = {
      GIT_ASKPASS  = "${path.module}/source/.git-askpass.sh"
      GIT_USERNAME = var.git_username
      GIT_PASSWORD = var.git_auth_token
    }
  }

  lifecycle {
    precondition {
      condition     = !var.create_hosted_source_repository || (var.git_username != "" && var.git_auth_token != "")
      error_message = "git_username and git_auth_token are required when create_hosted_source_repository is true."
    }
  }
}

resource "oci_devops_deploy_artifact" "container_image" {
  argument_substitution_mode = "SUBSTITUTE_PLACEHOLDERS"
  deploy_artifact_type       = "DOCKER_IMAGE"
  project_id                 = oci_devops_project.app.id
  display_name               = "${var.app_name}-container-image"

  deploy_artifact_source {
    deploy_artifact_source_type = "OCIR"
    image_uri                   = "${lower(var.ocir_region_key)}.ocir.io/${var.ocir_namespace}/${var.image_repository}:$${IMAGE_TAG}"
  }
}

resource "oci_devops_build_pipeline" "app" {
  project_id   = oci_devops_project.app.id
  display_name = "${var.app_name}-build-pipeline"

  build_pipeline_parameters {
    items {
      name          = "IMAGE"
      default_value = local.container_image
      description   = "Full container image URL."
    }

    items {
      name          = "IMAGE_TAG"
      default_value = var.image_tag
      description   = "Container image tag."
    }

    items {
      name          = "PLATFORM"
      default_value = var.container_platform
      description   = "Container build platform."
    }
  }
}

resource "oci_devops_build_pipeline_stage" "build" {
  build_pipeline_id         = oci_devops_build_pipeline.app.id
  build_pipeline_stage_type = "BUILD"
  display_name              = "${var.app_name}-managed-build"
  build_spec_file           = var.build_spec_file
  image                     = var.build_image
  primary_build_source      = "app"

  build_pipeline_stage_predecessor_collection {
    items {
      id = oci_devops_build_pipeline.app.id
    }
  }

  build_runner_shape_config {
    build_runner_type = var.build_runner_type
  }

  build_source_collection {
    items {
      name            = "app"
      connection_type = var.create_hosted_source_repository ? "DEVOPS_CODE_REPOSITORY" : var.source_connection_type
      branch          = var.source_repository_branch
      connection_id   = var.create_hosted_source_repository ? null : (var.source_connection_id != "" ? var.source_connection_id : null)
      repository_id   = var.create_hosted_source_repository ? oci_devops_repository.source[0].id : (var.source_repository_id != "" ? var.source_repository_id : null)
      repository_url  = var.create_hosted_source_repository ? oci_devops_repository.source[0].http_url : var.source_repository_url
    }
  }

  depends_on = [terraform_data.push_source]
}

resource "oci_devops_build_pipeline_stage" "deliver" {
  build_pipeline_id         = oci_devops_build_pipeline.app.id
  build_pipeline_stage_type = "DELIVER_ARTIFACT"
  display_name              = "${var.app_name}-deliver-image"

  build_pipeline_stage_predecessor_collection {
    items {
      id = oci_devops_build_pipeline_stage.build.id
    }
  }

  deliver_artifact_collection {
    items {
      artifact_id   = oci_devops_deploy_artifact.container_image.id
      artifact_name = "container-image"
    }
  }

  depends_on = [oci_artifacts_container_repository.app]
}

resource "oci_devops_build_run" "app" {
  count             = var.run_build ? 1 : 0
  build_pipeline_id = oci_devops_build_pipeline.app.id
  display_name      = "${var.app_name}-${var.image_tag}"

  commit_info {
    repository_branch = var.source_repository_branch
    repository_url    = var.create_hosted_source_repository ? oci_devops_repository.source[0].http_url : var.source_repository_url
    commit_hash       = ""
  }

  build_run_arguments {
    items {
      name  = "IMAGE"
      value = local.container_image
    }

    items {
      name  = "IMAGE_TAG"
      value = var.image_tag
    }

    items {
      name  = "PLATFORM"
      value = var.container_platform
    }
  }

  depends_on = [oci_devops_build_pipeline_stage.deliver]
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
