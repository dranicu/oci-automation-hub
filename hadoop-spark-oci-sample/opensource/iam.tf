###############################################################################
# IAM - OKE Workload Identity for Object Storage access
#
# Created only when deploy_object_storage = true. OKE Workload Identity is NOT
# authorized through dynamic groups - per OCI docs, "You cannot currently use
# workload identities with dynamic groups". Instead, a policy grants `any-user`
# whose request.principal is a workload in THIS cluster + namespace direct access
# to the data bucket. Spark pods then reach Object Storage with short-lived,
# scoped tokens and no static keys.
#
# Ref: https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contenggrantingworkloadaccesstoresources.htm
#
# NOTE: creating policies requires IAM administration permission in the tenancy.
# Global IAM writes must run in the home region (provider = oci.home).
###############################################################################

resource "oci_identity_policy" "workload" {
  count    = var.deploy_object_storage ? 1 : 0
  provider = oci.home # global IAM writes must run in the home region

  compartment_id = var.compartment_ocid
  name           = "${var.cluster_name}-workload-policy"
  description    = "Allow ${var.cluster_name} OKE workloads to use the data bucket via Workload Identity"

  # Scope to workloads in this cluster + namespace (any service account, so both
  # the Spark driver and executors are covered). The second statement adds the
  # bucket-name condition for object operations (ListObjects/Get/Put/Delete).
  statements = [
    "Allow any-user to read buckets in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.cluster_id = '${module.oke.cluster_id}', request.principal.namespace = '${local.namespace}'}",
    "Allow any-user to manage objects in compartment id ${var.compartment_ocid} where all {request.principal.type = 'workload', request.principal.cluster_id = '${module.oke.cluster_id}', request.principal.namespace = '${local.namespace}', target.bucket.name = '${local.bucket_name}'}",
  ]
}
