# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# =============================================================================
# General
# =============================================================================
variable "tenancy_ocid" {
  description = "OCID of the tenancy (auto-populated by Resource Manager)."
  type        = string
}

variable "compartment_ocid" {
  description = "OCID of the compartment where resources will be created."
  type        = string
}

variable "region" {
  description = "OCI region for deployment."
  type        = string
}

variable "current_user_ocid" {
  description = "OCID of the current user (auto-populated by Resource Manager)."
  type        = string
  default     = ""
}

variable "resource_name_prefix" {
  description = "Prefix applied to all resource display names."
  type        = string
  default     = "rmstack"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9\\-]{0,19}$", var.resource_name_prefix))
    error_message = "Prefix must start with a letter and contain only alphanumeric characters and hyphens (max 20 chars)."
  }
}

# =============================================================================
# Network
# =============================================================================
variable "vcn_cidr_block" {
  description = "CIDR block for the VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "vcn_dns_label" {
  description = "DNS label for the VCN."
  type        = string
  default     = "rmvcn"
}

variable "subnet_cidr_block" {
  description = "CIDR block for the compute subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "subnet_dns_label" {
  description = "DNS label for the subnet."
  type        = string
  default     = "compute"
}

variable "subnet_is_public" {
  description = "Whether the subnet is public (true) or private (false)."
  type        = bool
  default     = true
}

variable "nsg_rules" {
  description = "Predefined NSG rule set: ssh_only, ssh_and_http, ssh_http_https, all_open, none."
  type        = string
  default     = "ssh_and_http"

  validation {
    condition     = contains(["ssh_only", "ssh_and_http", "ssh_http_https", "all_open", "none"], var.nsg_rules)
    error_message = "Must be one of: ssh_only, ssh_and_http, ssh_http_https, all_open, none."
  }
}

# =============================================================================
# Compute
# =============================================================================
variable "instance_count" {
  description = "Number of compute instances to deploy. Set to 0 to remove all."
  type        = number
  default     = 1

  validation {
    condition     = var.instance_count >= 0 && var.instance_count <= 20
    error_message = "Instance count must be between 0 and 20."
  }
}

variable "instance_shape" {
  description = "Compute instance shape (e.g., VM.Standard.E4.Flex)."
  type        = string
}

variable "instance_flex_ocpus" {
  description = "Number of OCPUs for flex shapes."
  type        = number
  default     = 1
}

variable "instance_flex_memory_in_gbs" {
  description = "Memory in GB for flex shapes."
  type        = number
  default     = 16
}

variable "instance_image_ocid" {
  description = "OCID of the OS image for the instances."
  type        = string
}

variable "instance_boot_volume_size_in_gbs" {
  description = "Boot volume size in GB."
  type        = number
  default     = 50
}

variable "ssh_public_key" {
  description = "SSH public key for instance access."
  type        = string
}

variable "assign_public_ip" {
  description = "Whether to assign public IPs to instances."
  type        = bool
  default     = true
}

variable "cloud_init_script" {
  description = "Optional cloud-init user data script (plain text, will be base64-encoded)."
  type        = string
  default     = ""
}

# =============================================================================
# Block Volume Configuration
# =============================================================================
variable "create_block_volumes" {
  description = "Whether to create and attach block volumes to each compute instance."
  type        = bool
  default     = false
}

variable "block_volume_size_in_gbs" {
  description = "Size of each block volume in GB."
  type        = number
  default     = 50

  validation {
    condition     = var.block_volume_size_in_gbs >= 50 && var.block_volume_size_in_gbs <= 32768
    error_message = "Block volume size must be between 50 and 32768 GB."
  }
}

variable "block_volume_vpus_per_gb" {
  description = "Volume performance units per GB. 0=Lower Cost, 10=Balanced, 20=Higher Performance, 30-120=Ultra High Performance."
  type        = number
  default     = 10

  validation {
    condition     = contains([0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120], var.block_volume_vpus_per_gb)
    error_message = "VPUs per GB must be 0, 10, 20, or 30-120 (in increments of 10)."
  }
}

variable "block_volume_attachment_type" {
  description = "Block volume attachment type: iscsi or paravirtualized."
  type        = string
  default     = "paravirtualized"

  validation {
    condition     = contains(["iscsi", "paravirtualized"], var.block_volume_attachment_type)
    error_message = "Attachment type must be 'iscsi' or 'paravirtualized'."
  }
}

# =============================================================================
# Benchmark — General
# =============================================================================
variable "run_benchmark" {
  description = "Whether to run benchmarks after instance provisioning."
  type        = bool
  default     = true
}

variable "benchmark_run_id" {
  description = "Change this value to trigger a new benchmark run on the next apply (e.g., increment: 1, 2, 3...)."
  type        = string
  default     = "1"
}

variable "ssh_private_key_secret_ocid" {
  description = "OCID of an OCI Vault secret containing the SSH private key (PEM format). Required to connect to instances for benchmarking."
  type        = string
  default     = ""
}

# =============================================================================
# Benchmark — Sysbench (CPU / Memory)
# =============================================================================
variable "run_sysbench" {
  description = "Run sysbench CPU benchmark on each instance."
  type        = bool
  default     = true
}

variable "sysbench_threads" {
  description = "Number of threads for sysbench. Set to 0 to auto-detect (use all available CPUs)."
  type        = number
  default     = 0

  validation {
    condition     = var.sysbench_threads >= 0 && var.sysbench_threads <= 256
    error_message = "Threads must be between 0 (auto) and 256."
  }
}

variable "sysbench_cpu_max_prime" {
  description = "Upper limit for prime number generation (higher = longer/harder test). Common values: 10000 (quick), 20000 (standard), 50000 (heavy), 100000 (extreme)."
  type        = number
  default     = 20000

  validation {
    condition     = var.sysbench_cpu_max_prime >= 100 && var.sysbench_cpu_max_prime <= 1000000
    error_message = "cpu-max-prime must be between 100 and 1000000."
  }
}

variable "sysbench_duration" {
  description = "Benchmark duration in seconds. Set to 0 for event-based mode."
  type        = number
  default     = 30

  validation {
    condition     = var.sysbench_duration >= 0 && var.sysbench_duration <= 3600
    error_message = "Duration must be between 0 and 3600 seconds."
  }
}

variable "sysbench_events" {
  description = "Maximum number of events (0 = unlimited, use duration instead)."
  type        = number
  default     = 0

  validation {
    condition     = var.sysbench_events >= 0 && var.sysbench_events <= 10000000
    error_message = "Events must be between 0 (unlimited) and 10000000."
  }
}

variable "run_memory_benchmark" {
  description = "Also run a sysbench memory bandwidth benchmark."
  type        = bool
  default     = false
}

variable "sysbench_memory_block_size" {
  description = "Memory block size for the memory benchmark (e.g., 1K, 1M, 4K)."
  type        = string
  default     = "1K"

  validation {
    condition     = can(regex("^[0-9]+[KMG]$", var.sysbench_memory_block_size))
    error_message = "Block size must be a number followed by K, M, or G (e.g., 1K, 1M)."
  }
}

variable "sysbench_memory_total_size" {
  description = "Total data size to transfer in the memory benchmark (e.g., 10G, 100G)."
  type        = string
  default     = "10G"

  validation {
    condition     = can(regex("^[0-9]+[KMG]$", var.sysbench_memory_total_size))
    error_message = "Total size must be a number followed by K, M, or G (e.g., 10G, 100G)."
  }
}

# =============================================================================
# Benchmark — FIO (Storage I/O)
# =============================================================================
variable "run_fio" {
  description = "Run FIO storage I/O benchmark on each instance. Requires block volumes to be enabled."
  type        = bool
  default     = false
}

variable "fio_test_pattern" {
  description = "FIO I/O test pattern: randread, randwrite, randrw, read, write."
  type        = string
  default     = "randrw"

  validation {
    condition     = contains(["randread", "randwrite", "randrw", "read", "write"], var.fio_test_pattern)
    error_message = "FIO test pattern must be one of: randread, randwrite, randrw, read, write."
  }
}

variable "fio_block_size" {
  description = "Block size for FIO I/O operations."
  type        = string
  default     = "4k"

  validation {
    condition     = can(regex("^[0-9]+[kmKM]$", var.fio_block_size))
    error_message = "FIO block size must be a number followed by k or m (e.g., 4k, 8k, 1m)."
  }
}

variable "fio_io_depth" {
  description = "Number of I/O units to keep in flight against the file."
  type        = number
  default     = 64

  validation {
    condition     = var.fio_io_depth >= 1 && var.fio_io_depth <= 1024
    error_message = "FIO I/O depth must be between 1 and 1024."
  }
}

variable "fio_num_jobs" {
  description = "Number of parallel FIO jobs. Set to 0 to auto-detect (use all available CPUs)."
  type        = number
  default     = 0

  validation {
    condition     = var.fio_num_jobs >= 0 && var.fio_num_jobs <= 256
    error_message = "FIO num_jobs must be between 0 (auto) and 256."
  }
}

variable "fio_duration" {
  description = "FIO test duration in seconds."
  type        = number
  default     = 60

  validation {
    condition     = var.fio_duration >= 5 && var.fio_duration <= 3600
    error_message = "FIO duration must be between 5 and 3600 seconds."
  }
}

variable "fio_file_size" {
  description = "Size of the test file for FIO. Should be large enough to avoid caching effects."
  type        = string
  default     = "4G"

  validation {
    condition     = can(regex("^[0-9]+[gGmM]$", var.fio_file_size))
    error_message = "FIO file size must be a number followed by g or m (e.g., 4G, 1G, 512m)."
  }
}

variable "fio_rwmixread" {
  description = "Percentage of reads in mixed read/write workload (only used with randrw pattern)."
  type        = number
  default     = 70

  validation {
    condition     = var.fio_rwmixread >= 0 && var.fio_rwmixread <= 100
    error_message = "FIO rwmixread must be between 0 and 100."
  }
}

variable "fio_direct" {
  description = "Use direct I/O (O_DIRECT), bypassing OS page cache. Recommended for storage benchmarks."
  type        = bool
  default     = true
}

# =============================================================================
# IAM Configuration (optional)
# =============================================================================
variable "create_dynamic_group" {
  description = "Create a Dynamic Group for benchmark instances. Set to false if one already exists."
  type        = bool
  default     = true
}

variable "create_policy" {
  description = "Create an IAM Policy allowing instances to push logs. Set to false if the policy already exists."
  type        = bool
  default     = true
}
