# eStargz Lazy Pulling on OCI VM

This repository provisions a small OCI environment and turns one Oracle Linux VM into an eStargz lazy-pull demo and benchmark node.

Current primary run mode:

```
local terminal -> terraform apply -> SSH to OCI VM -> login to registry -> run benchmark
```

## What It Does

Terraform provisions:

- one VCN
- one public subnet and one private subnet
- Internet Gateway and NAT Gateway
- route tables and security list
- one Oracle Linux 9 compute VM with a 200 GB boot volume

Cloud-init configures the VM with:

- root filesystem expansion so `df -h /` shows the enlarged boot volume
- `containerd`
- `stargz-snapshotter`
- `nerdctl`
- CNI plugins
- helper scripts for status, cache reset, benchmark execution, and summary generation

The benchmark compares first container startup for:

```
eStargz image + stargz snapshotter
regular image + overlayfs
```

This demonstrates whether lazy pulling reduces time-to-first-run for a large image on a plain OCI VM, without Kubernetes or OKE.

## Terraform Inputs

Main customer/demo inputs live in `terraform.tfvars`.

Required local values:

```
ssh_public_key = "~/.ssh/id_rsa.pub" # CHANGE ME
registry       = "fra.ocir.io"       # CHANGE ME if using another OCIR region
```

Benchmark image inputs:

```
estargz_image  = "fra.ocir.io/<namespace>/<repo>/<image>:<estargz-tag>"
regular_image  = "fra.ocir.io/<namespace>/<repo>/<image>:<regular-tag>"
run_validation = false
```

Keep `run_validation = false` for private OCIR images unless registry credentials are already configured on the VM. The usual demo flow is to SSH first, run `nerdctl login`, then start the benchmark manually.

Do not put OCIR auth tokens or passwords in Terraform variables, tfvars files, outputs, logs, or state.

## Customer Image Mode

To benchmark customer images, provide one or both image references:

```
estargz_image = "fra.ocir.io/<namespace>/<repo>/<image>:<estargz-tag>"
regular_image = "fra.ocir.io/<namespace>/<repo>/<image>:<regular-tag>"
```

The most useful comparison uses both images. If both are empty, `test-estargz.sh` exits with a clear message showing what to set.

After the VM is created, the same values are written to:

```
/etc/estargz-benchmark.env
```

You can edit that file on the VM to test different images without redeploying Terraform.

## Deploy

From this repository:

```
cp provider.auto.tfvars.example provider.auto.tfvars
```

Edit `provider.auto.tfvars` and fill in your OCI provider values and compartment OCIDs. 

Then run:

```
terraform init
terraform validate
terraform plan
terraform apply
```

After apply, get the VM IP from output:

```
terraform output linux_instances
```

SSH to the VM:

```
ssh -i ~/.ssh/id_rsa opc@<public_ip>
```

Wait for cloud-init:

```
sudo cloud-init status --wait --long
```

On a freshly created VM this should finish without errors.

Cloud-init logs are written to:

```
/var/log/estargz-cloudinit.log
/var/log/cloud-init-output.log
```

## Run Helper Scripts

Check installation status:

```
sudo /usr/local/bin/estargz-status.sh
```

This also prints `df -h /` so you can confirm the 200 GB boot volume is visible inside the VM.

Manual checks:

```
df -h /
lsblk
sudo pvs
sudo vgs
sudo lvs
sudo systemctl status containerd --no-pager
sudo systemctl status stargz-snapshotter --no-pager
sudo /usr/local/bin/ctr plugins ls | grep -E 'stargz|overlayfs|snapshot'
sudo /usr/local/bin/nerdctl version
sudo cat /etc/containerd/config.toml | grep -A5 -n 'proxy_plugins'
sudo cat /etc/estargz-benchmark.env
```

The important expected signals are:

```
/ is around 183G on a 200 GB boot volume
containerd is active
stargz-snapshotter is active
overlayfs plugin is ok
stargz plugin is ok
```

`nerdctl version` may warn that `buildctl` or `runc` version cannot be detected. Continue with the container run tests below; if container execution fails, install/fix the missing runtime binary.

Basic public-image run tests:

```
sudo /usr/local/bin/nerdctl --snapshotter overlayfs run --rm docker.io/library/busybox:latest true
sudo /usr/local/bin/nerdctl --snapshotter stargz run --rm docker.io/library/busybox:latest true
```

For private OCIR images, login first:

```
sudo /usr/local/bin/nerdctl login fra.ocir.io
```

For OCIR, the username is typically:

```
<tenancy-namespace>/<oci-username>
```

Use an OCI auth token as the password, not the OCI Console password.

Run the benchmark:

```
sudo /usr/local/bin/test-estargz.sh
```

The benchmark script:

1. resets containerd and stargz-snapshotter state
2. runs the eStargz image with `stargz`
3. resets state again
4. runs the regular image with `overlayfs`
5. writes raw timing output to `/var/log/estargz-benchmark.log`
6. writes a clean summary to `/var/log/estargz-summary.txt`

View the results:

```
sudo cat /var/log/estargz-summary.txt
sudo cat /var/log/estargz-benchmark.log
```

The summary file is the easiest artifact to copy into a demo note, customer email, or overview page. It includes the images, snapshotters, `real` times, initial downloaded amount shown by `nerdctl`, root filesystem size, and improvement percentage when both test cases complete.

Inspect images, containers, snapshots, and cache after a run:

```
sudo /usr/local/bin/nerdctl images
sudo /usr/local/bin/nerdctl ps
sudo /usr/local/bin/nerdctl ps -a
sudo /usr/local/bin/ctr images ls
sudo /usr/local/bin/ctr snapshots ls
sudo du -sh /var/lib/containerd
sudo du -sh /var/lib/containerd-stargz-grpc
```

The benchmark uses `nerdctl run --rm`, so completed containers are removed automatically and `nerdctl ps -a` may be empty. Run these inspection commands after a benchmark case and before another cache reset if you want to see the current image/cache state.

Example observed result with a large image pair:

```
eStargz image + stargz:
  downloaded initially: a few KiB
  real time: a few seconds

regular image + overlayfs:
  downloaded: multiple GiB
  real time: minutes
```

Reset the cache manually:

```
sudo /usr/local/bin/reset-estargz-cache.sh
```

Override the command executed inside the container:

```
sudo CONTAINER_CMD="python -c 'print(123)'" /usr/local/bin/test-estargz.sh
```

Override images without changing Terraform:

```
sudo ESTARGZ_IMAGE="fra.ocir.io/<namespace>/<repo>/<image>:<estargz-tag>" \
     REGULAR_IMAGE="fra.ocir.io/<namespace>/<repo>/<image>:<regular-tag>" \
     /usr/local/bin/test-estargz.sh
```

For persistent overrides, edit:

```
/etc/estargz-benchmark.env
```

Example persistent customer override:

```
sudo tee /etc/estargz-benchmark.env >/dev/null <<'EOF'
REGISTRY="fra.ocir.io"
ESTARGZ_IMAGE="fra.ocir.io/<namespace>/<repo>/<image>:<estargz-tag>"
REGULAR_IMAGE="fra.ocir.io/<namespace>/<repo>/<image>:<regular-tag>"
CONTAINER_CMD="true"
LOG_FILE="/var/log/estargz-benchmark.log"
SUMMARY_FILE="/var/log/estargz-summary.txt"
EOF
```

## Repository Map

Terraform root files:

```
main.tf                 wires network and compute modules together
variables.tf            declares root input variables
terraform.tfvars        local demo values for network, VM, registry, and image inputs
provider.auto.tfvars.example  safe template for local OCI provider credentials/settings
outputs.tf              Terraform outputs, currently VM information
```

Terraform modules:

```
modules/network/         creates VCN, gateways, route tables, security list, and subnets
modules/instances/       creates the OCI compute VM and renders cloud-init
userdata/cloudinit.sh.tftpl  VM bootstrap template
```

## What This Does Not Do

- It does not create the eStargz image from a regular image.
- It does not push images to OCIR.
- It does not configure CRI-O, ALS, OKE, or Kubernetes.
- It does not store OCIR credentials.

For this version, the customer provides an existing regular image and, ideally, the matching eStargz image. The automation provides a clean VM and a repeatable benchmark harness.
