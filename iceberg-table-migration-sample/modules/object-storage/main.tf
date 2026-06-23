// Copyright (c) 2021, Oracle and/or its affiliates. All rights reserved.
// Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.
data "oci_objectstorage_namespace" "this" {
  compartment_id = var.oci_provider["tenancy_ocid"]
}

resource "oci_objectstorage_bucket" "this" {
  for_each              = var.bucket_params
  compartment_id        = var.compartments[each.value.compartment_name]
  name                  = each.value.name
  namespace             = data.oci_objectstorage_namespace.this.namespace
  access_type           = each.value.access_type
  storage_tier          = each.value.storage_tier
  object_events_enabled = each.value.events_enabled
  kms_key_id            = length(var.kms_key_ids) == 0 || each.value.kms_key_name == "" ? "" : var.kms_key_ids[each.value.kms_key_name]
}

resource "terraform_data" "empty_bucket_on_destroy" {
  for_each = {
    for bucket_key, bucket in var.bucket_params : bucket_key => bucket
    if bucket.force_destroy
  }

  input = {
    bucket_name = oci_objectstorage_bucket.this[each.key].name
    namespace   = data.oci_objectstorage_namespace.this.namespace
    region      = var.oci_provider["region"]
  }

  depends_on = [oci_objectstorage_bucket.this]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["PowerShell", "-NoProfile", "-Command"]
    command     = "oci os object bulk-delete --namespace-name '${self.input.namespace}' --bucket-name '${self.input.bucket_name}' --region '${self.input.region}' --force"
  }
}
