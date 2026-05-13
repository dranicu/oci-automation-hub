# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

########################### NETWORK #################################

vcn_params = {
  estargz_vcn = {
    compartment_name = "sandbox"
    display_name     = "estargz-vcn"
    vcn_cidr         = "10.20.0.0/16"
    dns_label        = "estargz"
  }
}

subnet_params = {
  estargz_public = {
    display_name      = "estargz-public"
    cidr_block        = "10.20.1.0/24"
    dns_label         = "estgzpub"
    is_subnet_private = false
    sl_name           = "estargz_sl"
    rt_name           = "estargz_public"
    vcn_name          = "estargz_vcn"
  }
  estargz_private = {
    display_name      = "estargz-private"
    cidr_block        = "10.20.2.0/24"
    dns_label         = "estgzpriv"
    is_subnet_private = true
    sl_name           = "estargz_sl"
    rt_name           = "estargz_private"
    vcn_name          = "estargz_vcn"
  }
}

igw_params = {
  estargz_igw = {
    display_name = "estargz-igw"
    vcn_name     = "estargz_vcn"
  },
}

ngw_params = {
  estargz_ngw = {
    display_name = "estargz-ngw"
    vcn_name     = "estargz_vcn"
  },
}

rt_params = {
  estargz_public = {
    display_name = "estargz-public-rt"
    vcn_name     = "estargz_vcn"

    route_rules = [
      {
        destination = "0.0.0.0/0"
        use_igw     = true
        igw_name    = "estargz_igw"
        ngw_name    = null
      },
    ]
  },
  estargz_private = {
    display_name = "estargz-private-rt"
    vcn_name     = "estargz_vcn"

    route_rules = [
      {
        destination = "0.0.0.0/0"
        use_igw     = false
        igw_name    = null
        ngw_name    = "estargz_ngw"
      },
    ]
  },
}

sl_params = {
  estargz_sl = {
    vcn_name     = "estargz_vcn"
    display_name = "estargz-sl"

    egress_rules = [
      {
        stateless   = "false"
        protocol    = "all"
        destination = "0.0.0.0/0"
      },
    ]

    ingress_rules = [
      {
        stateless   = "false"
        protocol    = "all"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_options = []
        udp_options = []
      },
    ]
  }
}

############################## COMPUTE ##################################

linux_images = {
  eu-frankfurt-1 = {
    oel9 = "ocid1.image.oc1.eu-frankfurt-1.aaaaaaaap6fyk44edftzyywudj4ofztrjsq7d47qtslsd74rlzlm3hu52xca" #Oracle-Linux-9.6-2025.11.20-0
  }
  us-ashburn-1 = {
    oel9 = "ocid1.image.oc1.iad.aaaaaaaaglxne5nh73mxqppl3fkzkqdlda3k22y6oyxcvy6gcaxxsym54mca"
  }
}

instance_params = {
  estargz_benchmark_vm = {
    ad                   = 1
    shape                = "VM.Standard.E5.Flex"
    hostname             = "estargz-benchmark"
    boot_volume_size     = 200
    preserve_boot_volume = false
    assign_public_ip     = true
    compartment_name     = "sandbox"
    subnet_name          = "estargz-public"
    freeform_tags = {
      "client" : "vfo",
      "department" : "vfo"
    }
    block_vol_att_type = "iscsi"
    encrypt_in_transit = true
    fd                 = null
    image_version      = "oel9"
    ssh_private_key    = "~/.ssh/id_rsa" # CHANGE ME - path to SSH private key
    script_tf_string   = "TEST_HUR_1"
    ocpus              = 1
    memory_in_gbs      = 16
  }
}

ssh_public_key = "~/.ssh/id_rsa.pub" # CHANGE ME - path to SSH public key

kms_key_ids = {}
registry    = "fra.ocir.io" # CHANGE ME if using another OCIR region, e.g. iad.ocir.io

# Benchmark inputs. Keep run_validation=false for private images unless registry auth is already configured on the VM.
estargz_image  = "fra.ocir.io/<namespace>/<repo>/<image>:<estargz-tag>" # CHANGE ME - eStargz image to test
regular_image  = "fra.ocir.io/<namespace>/<repo>/<image>:<regular-tag>" # CHANGE ME - regular baseline image for overlayfs
run_validation = false                                                  # true runs the benchmark during cloud-init; private OCIR images usually need manual nerdctl login first
