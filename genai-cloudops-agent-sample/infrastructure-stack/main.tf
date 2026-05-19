# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  app_dynamic_group_matching_rule = "All {instance.compartment.id = '${var.compartment_ocid}'}"
  container_dynamic_group_matching_rule = "ALL {resource.type = 'computecontainerinstance', resource.compartment.id = '${var.compartment_ocid}'}"
}

locals {
  image_map = {
    "Oracle Linux 9" = "ocid1.image.oc1.iad.aaaaaaaaglxne5nh73mxqppl3fkzkqdlda3k22y6oyxcvy6gcaxxsym54mca"
    "Ubuntu 24.04"   = "ocid1.image.oc1.iad.aaaaaaaa5m2iw4g2glbqb2pzua2kyumj56j2zvzhusmbkqumcluf4oxh3dia"
  }

  selected_image_ocid = local.image_map[var.image_id]
}

module "app_dynamic_group" {
  source = "./modules/dynamic-group"
  tenancy_ocid   = var.tenancy_ocid
  name           = "${var.display_name_prefix}_dynamic_group"
  description    = "${var.component_description} - Dynamic Group"
  matching_rule  = local.app_dynamic_group_matching_rule
}

module "app_iam_policy" {
  source = "./modules/iam-policy"

  compartment_ocid = var.compartment_ocid
  display_name           = "${var.display_name_prefix}_app_iam_policy"
  description    = "${var.component_description} - IAM Policy"
  statements     = [
    "Allow dynamic-group id ${module.app_dynamic_group.id} to use log-content in compartment id ${var.compartment_ocid}",
    "allow any-user to use stream-push in compartment id ${var.compartment_ocid} where all {request.principal.type='serviceconnector', request.principal.compartment.id='${var.compartment_ocid}'}"
  ]
}

module "container_dynamic_group" {
  source = "./modules/dynamic-group"
  tenancy_ocid   = var.tenancy_ocid
  name           = "${var.display_name_prefix}_container_dynamic_group"
  description    = "${var.component_description} - Container Dynamic Group"
  matching_rule  = local.container_dynamic_group_matching_rule
}

module "container_iam_policy" {
  source = "./modules/iam-policy"

  compartment_ocid = var.compartment_ocid
  display_name           = "${var.display_name_prefix}_container_iam_policy"
  description    = "${var.component_description} - IAM Policy"
  statements     = [
    "Allow dynamic-group id ${module.container_dynamic_group.id} to read repos in compartment id ${var.compartment_ocid}",
    "ALLOW dynamic-group id ${module.container_dynamic_group.id} to manage all-resources in compartment id ${var.compartment_ocid}"
  ]
}

module "log_group" {
  source = "./modules/log-group"
  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_log_group"
  description      = "${var.component_description} - Log Group"
  defined_tags  = try(var.tags.definedTags, null)
  freeform_tags    = try(var.tags.freeformTags, null)

}

module "unified_agent_configuration" {
  source = "./modules/log-agent"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_unified_agent_config"
  description      = "${var.component_description} - Unified Agent Configuration"
  is_enabled       = true

  group_list   = [module.app_dynamic_group.id]
  log_object_id = module.log_group.custom_log_id

  paths        =  ["/home/opc/test/random_exceptions.txt"]
  source_name  = "logs"
  parser_type  = "NONE"
  message_key  = "message"
}

module "stream" {
  source = "./modules/streams"

  name               = "${var.display_name_prefix}_stream"
  partitions         = 1
  compartment_ocid   = var.compartment_ocid
}

module "service_connector" {
  source = "./modules/service-connector"


  compartment_ocid        = var.compartment_ocid
  display_name            = "${var.display_name_prefix}_service_connector"
  description             = "${var.component_description} - Service Connector"
  source_log_group_id     = module.log_group.id
  log_id                  = module.log_group.custom_log_id
  target_stream_id        = module.stream.id
}

module "genai_agent_rag" {
  source = "./modules/genai-agent-rag"
  kb_file_path = "${path.module}/kb-file/kb-file.pdf"
  tenancy_ocid = var.tenancy_ocid
  compartment_ocid = var.compartment_ocid
  display_name_prefix = var.display_name_prefix
  component_description = var.component_description
}

module "vm_instances" {
  source = "./modules/vm-instance"
  compartment_ocid = var.compartment_ocid

  instances = {
    vm1 = {
      display_name        = "${var.display_name_prefix}_testvm-1"
      availability_domain = var.availability_domain
      shape               = var.instance_shape
      image_id            = local.selected_image_ocid
      subnet_id           = var.subnet_id
      ocpus               = 2
      memory_in_gbs       = 16
      ssh_public_keys     = [var.ssh_public_keys]
    }

    vm2 = {
      display_name        = "${var.display_name_prefix}_testvm-2"
      availability_domain = var.availability_domain
      shape               = var.instance_shape
      image_id            = local.selected_image_ocid
      subnet_id           = var.subnet_id
      ocpus               = 2
      memory_in_gbs       = 16
      ssh_public_keys     = [var.ssh_public_keys]
    }
  }
}

module "mcp_ocir" {
  source = "./modules/ocir"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_ocir/mcp"
  is_public        = false
  is_immutable     = false
}

module "app_ocir" {
  source = "./modules/ocir"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_ocir/app"
  is_public        = false
  is_immutable     = false
}

module "cpu_alarm"{
  source = "./modules/alarm-definition"

  compartment_ocid = var.compartment_ocid
  display_name     = "${var.display_name_prefix}_cpu_utilization_alarm"
  stream_id = module.stream.id
}