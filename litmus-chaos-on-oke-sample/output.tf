# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

output "litmus_namespace" {
  description = "Namespace where Litmus is installed"
  value       = kubernetes_namespace_v1.litmus.metadata[0].name
}

output "litmus_release" {
  description = "Helm release name"
  value       = helm_release.litmus.name
}

output "litmus_frontend_load_balancer_ip" {
  description = "External IP for Litmus frontend service (when available)"
  value = try(
    data.kubernetes_service_v1.litmus_frontend.status[0].load_balancer[0].ingress[0].ip,
    null
  )
}
