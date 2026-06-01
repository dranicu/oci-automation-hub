# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
locals {
  source_dir = abspath("${path.module}/${var.source_dir}")
  image_url  = "${lower(var.ocir_region_key)}.ocir.io/${var.ocir_namespace}/${var.image_repository}:${var.image_tag}"

  source_files = [
    for file in fileset(local.source_dir, "**") : file
    if !startswith(file, "dist/")
    && !startswith(file, ".git/")
    && !startswith(file, "data/")
    && !startswith(file, "certs/")
    && !startswith(file, ".terraform/")
    && file != ".env"
  ]
}

resource "oci_artifacts_container_repository" "app" {
  count          = var.create_repository ? 1 : 0
  compartment_id = var.repository_compartment_id
  display_name   = var.image_repository
  is_public      = false

  lifecycle {
    precondition {
      condition     = var.repository_compartment_id != ""
      error_message = "repository_compartment_id is required when create_repository is true."
    }
  }
}

resource "docker_image" "app" {
  name         = local.image_url
  keep_locally = true

  build {
    context    = local.source_dir
    dockerfile = "Dockerfile"
    platform   = var.platform != "" ? var.platform : null
    tag        = [local.image_url]
  }

  triggers = {
    source_hash = sha256(join("", [for file in local.source_files : filesha256("${local.source_dir}/${file}")]))
  }
}

resource "docker_registry_image" "app" {
  name          = docker_image.app.name
  keep_remotely = true
  depends_on    = [oci_artifacts_container_repository.app]

  auth_config {
    address  = "${lower(var.ocir_region_key)}.ocir.io"
    username = var.registry_username
    password = var.registry_auth_token
  }
}
