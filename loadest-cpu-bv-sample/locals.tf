# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

locals {
  # Determine if the shape is a Flex shape
  is_flex_shape = length(regexall("Flex$", var.instance_shape)) > 0

  # Home region for Identity resources
  home_region = data.oci_identity_region_subscriptions.this.region_subscriptions[0].region_name

  # Default SSH login user, auto-detected from the image OS.
  # Ubuntu images log in as "ubuntu"; Oracle Linux / others use "opc".
  ssh_user = length(regexall("(?i)ubuntu", data.oci_core_image.instance_image.operating_system)) > 0 ? "ubuntu" : "opc"

  # SSH private key, retrieved from the OCI Vault secret
  effective_ssh_private_key = (
    var.ssh_private_key_secret_ocid != ""
    ? base64decode(data.oci_secrets_secretbundle.ssh_private_key[0].secret_bundle_content[0].content)
    : ""
  )

  # Common freeform tags
  common_tags = {
    "ManagedBy"   = "ResourceManager"
    "Stack"       = var.resource_name_prefix
    "DeployedBy"  = "Terraform"
  }

  # -------------------------------------------------------------------
  # Cloud-Init: merge sysbench install script + optional user script
  #
  # Uses MIME multipart so both scripts execute independently.
  # The sysbench installer always runs; the user script is appended
  # only if provided.
  # -------------------------------------------------------------------
  # Whether any benchmark needs the tools install script
  any_benchmark_enabled = var.run_benchmark && (var.run_sysbench || var.run_fio)

  tools_install_script = file("${path.module}/scripts/cloud-init.sh")

  # Build multipart cloud-init when benchmark is enabled
  cloud_init_parts = local.any_benchmark_enabled ? concat(
    [
      {
        content_type = "text/x-shellscript"
        content      = local.tools_install_script
        filename     = "install-benchmark-tools.sh"
      }
    ],
    var.cloud_init_script != "" ? [
      {
        content_type = "text/x-shellscript"
        content      = var.cloud_init_script
        filename     = "user-custom.sh"
      }
    ] : []
  ) : (
    var.cloud_init_script != "" ? [
      {
        content_type = "text/x-shellscript"
        content      = var.cloud_init_script
        filename     = "user-custom.sh"
      }
    ] : []
  )

  # Render MIME multipart only if we have parts
  has_cloud_init = length(local.cloud_init_parts) > 0

  mime_boundary = "MIMEBOUNDARY"

  cloud_init_multipart = local.has_cloud_init ? join("\n", concat(
    [
      "Content-Type: multipart/mixed; boundary=\"${local.mime_boundary}\"",
      "MIME-Version: 1.0",
      "",
    ],
    flatten([
      for part in local.cloud_init_parts : [
        "--${local.mime_boundary}",
        "Content-Type: ${part.content_type}; charset=\"us-ascii\"",
        "Content-Disposition: attachment; filename=\"${part.filename}\"",
        "",
        part.content,
        "",
      ]
    ]),
    ["--${local.mime_boundary}--", ""]
  )) : ""

  # -------------------------------------------------------------------
  # NSG ingress rules map
  # Each rule set is a list of objects describing allowed ingress traffic.
  # -------------------------------------------------------------------
  nsg_ingress_rules = {
    none = []

    ssh_only = [
      {
        description = "Allow SSH from anywhere"
        protocol    = "6" # TCP
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_port    = 22
      }
    ]

    ssh_and_http = [
      {
        description = "Allow SSH from anywhere"
        protocol    = "6"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_port    = 22
      },
      {
        description = "Allow HTTP from anywhere"
        protocol    = "6"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_port    = 80
      }
    ]

    ssh_http_https = [
      {
        description = "Allow SSH from anywhere"
        protocol    = "6"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_port    = 22
      },
      {
        description = "Allow HTTP from anywhere"
        protocol    = "6"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_port    = 80
      },
      {
        description = "Allow HTTPS from anywhere"
        protocol    = "6"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_port    = 443
      }
    ]

    all_open = [
      {
        description = "Allow all ingress"
        protocol    = "all"
        source      = "0.0.0.0/0"
        source_type = "CIDR_BLOCK"
        tcp_port    = null
      }
    ]
  }

  # Flatten the selected rules for iteration
  selected_nsg_rules = local.nsg_ingress_rules[var.nsg_rules]
}
