###############################################################################
# Terraform / provider configuration
#
# A single stack provisions everything in ONE apply: the OKE cluster and all OCI
# infrastructure (oci provider), plus a private operator VM whose cloud-init
# installs the in-cluster platform (Kerberos KDC, HDFS, Spark Operator). The
# platform is delivered as manifests + helm run from the operator INSIDE the VCN
# (see platform.tf / oke.tf), so there are no kubernetes/helm providers and the
# apply never needs to reach the cluster API - it works in Resource Manager with
# a fully private cluster.
###############################################################################

terraform {
  required_version = ">= 1.3.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.30.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.2.0"
    }
  }
}

provider "oci" {
  region = var.region
}

# Home-region alias. Global IAM writes (the Workload Identity dynamic group /
# policy in iam.tf, and any module IAM) must be executed in the tenancy home
# region, not the working region.
provider "oci" {
  alias  = "home"
  region = local.home_region
}
