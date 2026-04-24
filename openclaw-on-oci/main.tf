# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  discovery_candidates_json_b64 = base64encode(file("${path.module}/discovery/01-oci-genai-chat-candidates.json"))
  discovery_script_py_b64       = base64encode(file("${path.module}/discovery/02-discover-oci-genai-chat-models.py"))
  apply_openclaw_models_py_b64  = base64encode(file("${path.module}/discovery/03-apply-openclaw-models.py"))
  discovery_service_unit_b64    = base64encode(file("${path.module}/systemd/openclaw-model-discovery.service"))

  openclaw_cloud_init_user_data = templatefile("${path.module}/cloud-init/cloud-init.userdata.tftpl", {
    discovery_candidates_json_b64 = local.discovery_candidates_json_b64
    discovery_script_py_b64       = local.discovery_script_py_b64
    apply_openclaw_models_py_b64  = local.apply_openclaw_models_py_b64
    discovery_service_unit_b64    = local.discovery_service_unit_b64
    oci_genai_api_key             = var.oci_genai_api_key
  })
}
