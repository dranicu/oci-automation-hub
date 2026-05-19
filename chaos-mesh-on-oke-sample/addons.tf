# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_containerengine_addon" "metrics_server" {
  count                            = var.enable_metrics_server ? 1 : 0
  cluster_id                       = oci_containerengine_cluster.chaosmesh.id
  addon_name                       = "KubernetesMetricsServer"
  remove_addon_resources_on_delete = true

  depends_on = [oci_containerengine_node_pool.chaosmesh-pool, oci_containerengine_addon.cert_manager]
}

resource "oci_containerengine_addon" "cert_manager" {
  count                            = var.enable_cert_manager ? 1 : 0
  cluster_id                       = oci_containerengine_cluster.chaosmesh.id
  addon_name                       = "CertManager"
  remove_addon_resources_on_delete = true

  depends_on = [oci_containerengine_node_pool.chaosmesh-pool]
}