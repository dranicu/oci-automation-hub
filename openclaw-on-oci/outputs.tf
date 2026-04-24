# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "instance_id" {
  description = "OCID of the OpenClaw compute instance."
  value       = oci_core_instance.openclaw.id
}

output "instance_display_name" {
  description = "Display name of the OpenClaw compute instance."
  value       = oci_core_instance.openclaw.display_name
}

output "instance_public_ip" {
  description = "Public IP address assigned to the OpenClaw instance primary VNIC."
  value       = oci_core_instance.openclaw.public_ip
}

output "instance_private_ip" {
  description = "Private IP address assigned to the OpenClaw instance primary VNIC."
  value       = oci_core_instance.openclaw.private_ip
}

output "openclaw_discovery_output_path" {
  description = "Path on the VM where the generated OCI GenAI chat model catalog is written."
  value       = "/opt/openclaw/runtime/03-oci-genai-chat-models.json"
}
