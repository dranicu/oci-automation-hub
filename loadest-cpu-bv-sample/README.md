# OCI Resource Manager — VCN + Compute + Block Volume + Benchmark Stack

## Overview

This Terraform stack deploys a complete networking foundation, configurable compute instances with optional block volumes, and runs **sysbench CPU/memory** and **FIO storage I/O** benchmarks automatically on each instance. Designed for **OCI Resource Manager** with a `schema.yaml` that renders a rich configuration form.

## What Gets Deployed

### Networking
- VCN with configurable CIDR, Internet/NAT/Service Gateways, Route Tables, Subnet, NSG

### Compute
- 1-20 Compute Instances (configurable, flex shape support, spread across ADs)
- IMDSv2 enforced, Oracle agent plugins enabled

### Block Volumes (optional)
- One block volume per compute instance
- Configurable size (50 GB - 32 TB), performance tier (VPUs/GB), and attachment type (paravirtualized or iSCSI)
- Automatically formatted (ext4) and mounted at `/mnt/fio-test` when FIO benchmark is enabled

### Benchmarks

#### Sysbench (CPU / Memory)
- **CPU benchmark** runs automatically on each instance after provisioning
- **Memory benchmark** optionally available
- Configurable threads, duration, workload intensity, and event limits

#### FIO (Storage I/O)
- **Storage I/O benchmark** runs on block volumes attached to each instance
- Configurable test pattern (randread, randwrite, randrw, read, write), block size, I/O depth, parallelism
- Includes automatic sequential read throughput baseline
- Requires block volumes to be enabled

### Results Delivery
- Full results stream into **Resource Manager Apply Logs** in real-time
- Summary visible in **Stack Outputs** panel
- Results pushed to **OCI Logging** (Log Group per stack, separate Custom Logs for sysbench and FIO)

## SSH Private Key — Secure Handling

The benchmarks use Terraform `remote-exec` provisioners which need SSH access. Two methods are available:

| Method | Security | How |
|---|---|---|
| **OCI Vault Secret** (recommended) | Key never leaves Vault; retrieved at apply time only | Select a Vault secret OCID in the RM form |
| **Direct Paste** (fallback) | Key stored in RM stack variables (encrypted at rest) | Paste PEM content directly; field only appears if no Vault secret is selected |

### Setting Up the Vault Secret

1. **Create a Vault** (if you don't have one): OCI Console > Identity & Security > Vault > Create Vault
2. **Create a Secret**: In your Vault, click Create Secret > paste your SSH private key (full PEM content) as the secret value
3. **Use in Stack**: When configuring the stack, select the secret from the "SSH Private Key - Vault Secret" dropdown

## Benchmark Parameters

### Sysbench (CPU / Memory)

| Parameter | Default | Description |
|---|---|---|
| **Run Sysbench** | `true` | Enable/disable sysbench |
| **Threads** | `0` (auto) | 0 = use all available CPUs |
| **CPU Max Prime** | `20000` | Workload intensity: 10K=quick, 20K=standard, 50K=heavy |
| **Duration** | `30s` | Test duration; longer = more stable results |
| **Events** | `0` (unlimited) | Cap total events instead of using time |
| **Memory Test** | `false` | Also run memory bandwidth test |

### FIO (Storage I/O)

| Parameter | Default | Description |
|---|---|---|
| **Run FIO** | `false` | Enable FIO benchmark (requires block volumes) |
| **Test Pattern** | `randrw` | randread, randwrite, randrw, read, write |
| **Block Size** | `4k` | 4k for IOPS testing, 1m for throughput |
| **I/O Depth** | `64` | Concurrent I/Os in flight |
| **Num Jobs** | `0` (auto) | Parallel workers; 0 = all CPUs |
| **Duration** | `60s` | Test duration |
| **File Size** | `4G` | Test file size (larger avoids caching) |
| **RW Mix Read** | `70%` | Read percentage for randrw pattern |
| **Direct I/O** | `true` | Bypass OS page cache (recommended) |

### Block Volumes

| Parameter | Default | Description |
|---|---|---|
| **Create Block Volumes** | `false` | Attach a BV to each instance |
| **Size** | `50 GB` | 50 GB - 32 TB |
| **VPUs/GB** | `10` | 0=Lower Cost, 10=Balanced, 20=Higher, 30-120=Ultra High |
| **Attachment Type** | `paravirtualized` | paravirtualized or iSCSI |

## Key Metrics

### Sysbench CPU
```
CPU speed:
    events per second:   1847.53      <-- PRIMARY METRIC (higher = better)

Latency (ms):
    avg:                  1.08        <-- Lower = better
    95th percentile:      1.10        <-- Consistent performance indicator
```

### FIO Storage
```
  Read IOPS:       125.3k            <-- Random read operations/sec
  Read Bandwidth:  489MiB/s          <-- Read throughput
  Write IOPS:      53.7k             <-- Random write operations/sec
  Write Bandwidth: 210MiB/s          <-- Write throughput
```

## Re-Running Benchmarks

1. **Change Run ID**: Edit stack > change `Benchmark Run ID` from `1` to `2` > Apply
2. **Change Parameters**: Modify any benchmark parameter > Apply
3. **Scale Instances**: Add new instances > benchmark runs automatically on new ones

## Reconfiguration on Re-Apply

| What | How |
|---|---|
| Add/remove VMs | Change `instance_count` |
| Change VM shape | Update `instance_shape` (forces recreation) |
| Change Flex OCPU/RAM | Update flex settings (in-place for flex shapes) |
| Add block volumes | Enable `Create Block Volumes` |
| Re-run benchmarks | Increment `benchmark_run_id` |
| Change benchmark intensity | Modify relevant benchmark parameters |
| Disable all benchmarks | Uncheck `Enable Benchmarks` |
| Enable FIO | Enable both `Create Block Volumes` and `Run FIO` |

## Deploy via Resource Manager

1.

<p align="center">
  <a href="https://cloud.oracle.com/resourcemanager/stacks/create?zipUrl=https://github.com/oracle-devrel/oci-automation-hub/releases/download/loadest-cpu-bv-sample/loadest-cpu-bv-sample.zip">
    <img src="https://docs.oracle.com/en-us/iaas/Content/Resources/Images/deploy-to-oracle-cloud.svg" alt="Deploy to Oracle Cloud" />
  </a>
</p>

2. **Configure**: Fill in the form. The sections appear in order: General, Network, Compute, Block Volumes, Benchmark General, Sysbench, FIO, IAM.

3. **Plan > Apply**: Benchmark results stream in the apply logs.

## Important Notes

- **SSH Key Required for Benchmarks**: Either provide a Vault secret OCID (recommended) or paste the private key directly. Without a key, benchmarks cannot connect to instances.
- **Public IP Required**: For RM to reach the instances, they need public IPs (or you need a bastion/VPN).
- **First Run**: Tools (sysbench, fio, OCI CLI) are installed via cloud-init on first boot. First run may take 1-2 extra minutes.
- **Subsequent Runs**: Tools are already installed, so re-runs only take the benchmark duration time.
- **FIO Needs Block Volumes**: FIO benchmarks require `Create Block Volumes = true`. The schema enforces this — the FIO section only appears when block volumes are enabled.

## Why sysbench + FIO?

| | sysbench | FIO |
|---|---|---|
| Purpose | CPU & memory benchmarking | Storage I/O benchmarking |
| License | GPL (open-source) | GPL (open-source) |
| Configurable | Threads, duration, workload | Pattern, depth, jobs, block size |
| Automation-friendly | CLI, no GUI | CLI, JSON output |
| Lightweight | ~1 MB | ~1 MB |

## File Structure

```
├── schema.yaml                  # RM UI form (General, Network, Compute, BV, Benchmarks, IAM)
├── provider.tf                  # OCI provider + home region alias
├── variables.tf                 # All variables organized by section
├── locals.tf                    # Computed values, SSH key resolution, cloud-init assembly
├── datasources.tf               # ADs, home region, Vault secret retrieval
├── network.tf                   # VCN, gateways, routes, subnet, NSG
├── compute.tf                   # Compute instances
├── block_volume.tf              # Block volumes + attachments
├── sysbench_benchmark.tf        # Sysbench CPU + memory benchmarks
├── fio_benchmark.tf             # FIO storage I/O benchmarks
├── logging.tf                   # OCI Logging (log group, custom logs, IAM)
├── outputs.tf                   # Stack outputs (network, compute, BV, benchmarks)
├── scripts/
│   └── cloud-init.sh           # Installs sysbench + fio + OCI CLI
├── terraform.tfvars.example     # Example variable values
└── README.md                    # This file
```
