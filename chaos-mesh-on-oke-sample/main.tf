# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

module "network" {
  source                   = "./modules/network"
  compartment_ocid         = var.compartment_ocid
  lb_subnet_cidr           = var.lb_subnet_cidr
  pods_subnet_cidr         = var.pods_subnet_cidr
  cidr_blocks              = var.cidr_blocks
  vcn_display_name         = var.vcn_display_name
  api_endpoint_subnet_cidr = var.api_endpoint_subnet_cidr
  nodepool_subnet_cidr     = var.nodepool_subnet_cidr

}


resource "oci_containerengine_cluster" "chaosmesh" {
  compartment_id     = var.compartment_ocid
  kubernetes_version = var.kubernetes_version
  name               = "chaosmesh"
  vcn_id             = module.network.vcn_id
  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = module.network.api_endpoint_subnet_id
    nsg_ids              = module.network.api_endpoint_nsg_ids
  }
  options {
    service_lb_subnet_ids = module.network.service_lb_subnet_ids
  }
  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }
  type       = "ENHANCED_CLUSTER"
  depends_on = [module.network]
}


resource "oci_containerengine_node_pool" "chaosmesh-pool" {
  compartment_id     = var.compartment_ocid
  cluster_id         = oci_containerengine_cluster.chaosmesh.id
  name               = "chaosmesh-pool"
  node_shape         = "VM.Standard.E5.Flex"
  kubernetes_version = var.kubernetes_version

  node_metadata = {
    user_data = filebase64("cloud-init.sh"),
    areLegacyImdsEndpointsDisabled = "true"
  }
  node_config_details {
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[0].name
      subnet_id           = module.network.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[1].name
      subnet_id           = module.network.node_pool_subnet_id
    }
    placement_configs {
      availability_domain = data.oci_identity_availability_domains.ads.availability_domains[2].name
      subnet_id           = module.network.node_pool_subnet_id
    }
    size    = 3
    nsg_ids = module.network.nodepool_nsg_ids
    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = 31
      pod_nsg_ids       = module.network.nodepool_nsg_ids
      pod_subnet_ids    = [module.network.node_pool_subnet_id]
    }
  }
  node_source_details {
    source_type = "IMAGE"
    image_id    = local.image_id
  }
  node_shape_config {
    memory_in_gbs = "16"
    ocpus         = 1
  }
  depends_on = [module.network]
}


data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

data "oci_containerengine_node_pool_option" "test_node_pool_option" {
  node_pool_option_id = "all"
}

data "oci_core_images" "shape_specific_images" {
  #Required
  compartment_id = var.tenancy_ocid
  shape          = "VM.Standard.E5.Flex"
}


data "oci_containerengine_node_pool_option" "node_pool_options" {
  compartment_id      = var.compartment_ocid
  node_pool_option_id = oci_containerengine_cluster.chaosmesh.id
}


locals {
  all_images          = data.oci_core_images.shape_specific_images.images
  all_sources         = data.oci_containerengine_node_pool_option.test_node_pool_option.sources
  compartment_images  = [for image in local.all_images : image.id if length(regexall("Oracle-Linux-[0-9]*.[0-9]*-20[0-9]*", image.display_name)) > 0]
  oracle_linux_images = [for source in local.all_sources : source.image_id if length(regexall("Oracle-Linux-[0-9]*.[0-9]*-20[0-9]*", source.source_name)) > 0]
  kubernetes_version  = replace(var.kubernetes_version, "v", "")
  linux_version       = "8"
  image_id = element([for source in data.oci_containerengine_node_pool_option.node_pool_options.sources :
  source.image_id if length(regexall("^Oracle-Linux-${local.linux_version}\\.\\d*-20.*-OKE-${local.kubernetes_version}-", source.source_name)) > 0], 0)
}

data "oci_identity_availability_domain" "ad" {
  compartment_id = var.tenancy_ocid
  ad_number      = 1
}

data "oci_containerengine_cluster_kube_config" "chaosmesh" {
  cluster_id = oci_containerengine_cluster.chaosmesh.id
}

provider "kubernetes" {
  host                   = yamldecode(data.oci_containerengine_cluster_kube_config.chaosmesh.content).clusters[0].cluster.server
  cluster_ca_certificate = base64decode(yamldecode(data.oci_containerengine_cluster_kube_config.chaosmesh.content).clusters[0].cluster["certificate-authority-data"])

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "oci"
    args = [
      "ce",
      "cluster",
      "generate-token",
      "--cluster-id",
      oci_containerengine_cluster.chaosmesh.id,
    ]
  }
}

provider "helm" {
  kubernetes = {
    host                   = yamldecode(data.oci_containerengine_cluster_kube_config.chaosmesh.content).clusters[0].cluster.server
    cluster_ca_certificate = base64decode(yamldecode(data.oci_containerengine_cluster_kube_config.chaosmesh.content).clusters[0].cluster["certificate-authority-data"])

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "oci"
      args = [
        "ce",
        "cluster",
        "generate-token",
        "--cluster-id",
        oci_containerengine_cluster.chaosmesh.id,
      ]
    }
  }
}

resource "kubernetes_namespace_v1" "chaosmesh" {
  metadata {
    name = var.chaosmesh_namespace
  }

  depends_on = [oci_containerengine_node_pool.chaosmesh-pool]
}

resource "helm_release" "chaosmesh" {
  name             = "chaos-mesh"
  repository       = "https://charts.chaos-mesh.org/"
  chart            = "chaos-mesh"
  namespace        = kubernetes_namespace_v1.chaosmesh.metadata[0].name
  create_namespace = false

  values = [yamlencode({

    chaosDaemon = {
      runtime = "crio"
      socketPath = "/var/run/crio/crio.sock"
    }

    dashboard = {
      service = {
        type = var.service_dashboard_type
      }
    }

  })]

  depends_on = [kubernetes_namespace_v1.chaosmesh]
}

data "kubernetes_service_v1" "chaosmesh_dashboard" {
  metadata {
    name      = "chaos-dashboard"
    namespace = kubernetes_namespace_v1.chaosmesh.metadata[0].name
  }

  depends_on = [helm_release.chaosmesh]
}
