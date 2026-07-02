###############################################################################
# OCI Bastion service
#
# Used to reach the worker nodes (break-glass SSH) and, when the Kubernetes API
# endpoint is private, to tunnel kubectl to it. Sessions are ephemeral and may
# only be opened from admin_cidr.
###############################################################################

resource "oci_bastion_bastion" "this" {
  bastion_type                 = "standard"
  compartment_id               = var.compartment_ocid
  target_subnet_id             = oci_core_subnet.nodes.id
  client_cidr_block_allow_list = [local.admin_cidr]
  name                         = "${var.cluster_name}-bastion"
  max_session_ttl_in_seconds   = 10800
  freeform_tags                = local.freeform_tags
}
