###############################################################################
# Data sources
###############################################################################

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.tenancy_ocid
}

# Region subscriptions - used to find the tenancy home region, where global IAM
# writes (dynamic groups / policies) must be executed.
data "oci_identity_region_subscriptions" "this" {
  tenancy_id = var.tenancy_ocid
}

# "All <region> Services" object - used to route private-subnet egress to the
# Oracle Services Network through the Service Gateway.
data "oci_core_services" "all_services" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}
