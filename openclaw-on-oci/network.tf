# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_vcn" "openclaw" {
  compartment_id = var.compartment_ocid
  display_name   = "openclaw-vcn"
  cidr_blocks    = ["10.0.0.0/16"]
  dns_label      = "openclawvcn"
}

resource "oci_core_internet_gateway" "openclaw" {
  compartment_id = var.compartment_ocid
  display_name   = "openclaw-igw"
  vcn_id         = oci_core_vcn.openclaw.id
  enabled        = true
}

resource "oci_core_route_table" "openclaw_public" {
  compartment_id = var.compartment_ocid
  display_name   = "openclaw-public-rt"
  vcn_id         = oci_core_vcn.openclaw.id

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.openclaw.id
  }
}

resource "oci_core_security_list" "openclaw_public" {
  compartment_id = var.compartment_ocid
  display_name   = "openclaw-public-sl"
  vcn_id         = oci_core_vcn.openclaw.id

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 443
      max = 443
    }
  }

  ingress_security_rules {
    protocol = "6"
    source   = "0.0.0.0/0"

    tcp_options {
      min = 18789
      max = 18789
    }
  }

  egress_security_rules {
    protocol    = "all"
    destination = "0.0.0.0/0"
  }
}

resource "oci_core_subnet" "openclaw_public" {
  compartment_id             = var.compartment_ocid
  display_name               = "openclaw-public-subnet"
  vcn_id                     = oci_core_vcn.openclaw.id
  cidr_block                 = "10.0.0.0/24"
  dns_label                  = "publicsubnet"
  route_table_id             = oci_core_route_table.openclaw_public.id
  security_list_ids          = [oci_core_security_list.openclaw_public.id]
  prohibit_public_ip_on_vnic = false
}
