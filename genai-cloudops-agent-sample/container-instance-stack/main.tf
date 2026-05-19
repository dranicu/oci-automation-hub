# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
module "mcp_server" {
    source = "./modules/mcp-ci"
    tenancy_ocid = var.tenancy_ocid
    region = var.region
    compartment_id = var.compartment_ocid
    availability_domain = var.availability_domain
    container_instance_display_name = "${var.display_name_prefix}-mcp-server-instance"
    container_image_url = var.mcp_container_image_url
    container_display_name = "${var.display_name_prefix}mcp-server-container"
    rag_agent_endpoint_id = var.rag_agent_endpoint_id
    shape = var.shape
    ocpus = var.ocpus
    memory_in_gbs = var.memory_in_gbs
    subnet_id = var.mcpsubnet_id
    assign_public_ip = var.mcpassign_public_ip
}

module "agent_application" {
    source = "./modules/app-ci"
    tenancy_ocid = var.tenancy_ocid
    region = var.region
    compartment_id = var.compartment_ocid
    availability_domain = var.availability_domain
    container_instance_display_name = "${var.display_name_prefix}-agent-app-instance"
    container_image_url = var.app_container_image_url
    container_display_name = "${var.display_name_prefix}agent-app-container"
    shape = var.shape
    ocpus = var.ocpus
    memory_in_gbs = var.memory_in_gbs
    subnet_id = var.appsubnet_id
    assign_public_ip = var.appassign_public_ip
    oci_genai_endpoint = var.oci_genai_endpoint
    oci_genai_model_id = var.oci_genai_model_id
    mcp_server_url = "http://${module.mcp_server.container_vnic_details[0].private_ip}:8080/mcp"
    }