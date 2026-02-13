# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

resource "oci_core_vcn" "dl_vcn" {
  cidr_block     = var.VCN_CIDR
  compartment_id = var.compartment_ocid
  display_name   = "Data locality - ${random_string.deploy_id.result}"
  dns_label      = var.vcn_dns_label
}

resource "oci_core_internet_gateway" "dl_internet_gateway" {
  compartment_id = var.compartment_ocid
  display_name   = "dl_internet_gateway"
  vcn_id         = oci_core_vcn.dl_vcn.id

}

resource "oci_core_nat_gateway" "nat_gateway" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.dl_vcn.id

  display_name   = "nat_gateway"
}

resource "oci_core_service_gateway" "dl_service_gateway" {
  compartment_id = var.compartment_ocid
  services {
    service_id = data.oci_core_services.net_services.services[0]["id"]
  }
  vcn_id       = oci_core_vcn.dl_vcn.id

  display_name = "dl Service Gateway"
}

resource "oci_core_route_table" "RouteForComplete" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.dl_vcn.id

  display_name   = "RouteTableForComplete"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.dl_internet_gateway.id
  }
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.dl_vcn.id

  display_name   = "private"

  route_rules {
    destination       = data.oci_core_services.net_services.services[0]["cidr_block"]
    destination_type  = "SERVICE_CIDR_BLOCK"
    network_entity_id = oci_core_service_gateway.dl_service_gateway.id
  }

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.nat_gateway.id
  }
}

resource "oci_core_security_list" "EdgeSubnet" {
  compartment_id = var.compartment_ocid
  display_name   = "Edge Subnet"
  vcn_id         = oci_core_vcn.dl_vcn.id


  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    tcp_options {
      max = 22
      min = 22
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 80
      min = 80
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 443
      min = 443
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 22
      min = 22
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = var.service_port
      min = var.service_port
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    tcp_options {
      max = 6443
      min = 6443
    }

    protocol = "6"
    source   = "0.0.0.0/0"
  }

  ingress_security_rules {
    protocol = "6"
    source   = var.VCN_CIDR
  }
}

resource "oci_core_security_list" "PrivateSubnet" {
  compartment_id = var.compartment_ocid
  display_name   = "Private"
  vcn_id         = oci_core_vcn.dl_vcn.id


  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }
  #  egress_security_rules {
  #    protocol    = "6"
  #    destination = var.VCN_CIDR
  #  }

  ingress_security_rules {
    protocol = "all"
    source   = var.VCN_CIDR
  }
  ingress_security_rules {
    description = "Allow  traffic  from load balancers (public subnet) to worker nodes"
    protocol    = "6"
    source      = "0.0.0.0/0"
    tcp_options {
      min = 30000
      max = 32767
    }
  }
}

resource "oci_core_subnet" "edge" {
  cidr_block        = var.edge_cidr
  display_name      = "edge"
  compartment_id    = var.compartment_ocid
  vcn_id            = oci_core_vcn.dl_vcn.id

  route_table_id    = oci_core_route_table.RouteForComplete.id
  security_list_ids = [oci_core_security_list.EdgeSubnet.id]
  dhcp_options_id   = oci_core_vcn.dl_vcn.default_dhcp_options_id
  dns_label         = "edge"
}

resource "oci_core_subnet" "private" {
  cidr_block                 = var.private_cidr
  display_name               = "private"
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.dl_vcn.id

  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.PrivateSubnet.id]
  dhcp_options_id            = oci_core_vcn.dl_vcn.default_dhcp_options_id
  prohibit_public_ip_on_vnic = "true"
  dns_label                  = "private"
}


