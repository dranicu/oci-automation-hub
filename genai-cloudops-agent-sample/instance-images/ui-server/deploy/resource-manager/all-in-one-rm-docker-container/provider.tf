# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 6.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = ">= 4.2.0"
    }
  }
}

provider "oci" {
  region = var.region
}

provider "docker" {
  host = var.docker_host

  registry_auth {
    address  = "${lower(var.ocir_region_key)}.ocir.io"
    username = var.registry_username
    password = var.registry_password
  }
}
