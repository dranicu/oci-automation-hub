# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# =============================================================================
# Storage Benchmark — FIO (Flexible I/O Tester)
#
# Flow:
#   1. wait_for_block_volume  → waits for BV attachment + sets up filesystem
#   2. fio_benchmark          → runs FIO tests, saves results
#   3. fio_collect_results    → pushes to OCI Logging + prints to RM logs
#
# Requires: create_block_volumes = true, run_fio = true, run_benchmark = true
# =============================================================================

# -----------------------------------------------------------------------------
# Wait for block volume attachment and prepare the device
# -----------------------------------------------------------------------------
resource "null_resource" "wait_for_block_volume" {
  count = var.run_benchmark && var.run_fio && var.create_block_volumes ? var.instance_count : 0

  triggers = {
    instance_id   = oci_core_instance.this[count.index].id
    attachment_id = oci_core_volume_attachment.this[count.index].id
  }

  connection {
    type        = "ssh"
    host        = var.subnet_is_public && var.assign_public_ip ? oci_core_instance.this[count.index].public_ip : oci_core_instance.this[count.index].private_ip
    user        = local.ssh_user
    private_key = local.effective_ssh_private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo '>>> Waiting for block volume attachment on ${oci_core_instance.this[count.index].display_name}...'",

      # For iSCSI attachments, connect using iscsiadm
      var.block_volume_attachment_type == "iscsi" ? join("\n", [
        "echo '>>> Connecting iSCSI target...'",
        "sudo iscsiadm -m node -o new -T ${oci_core_volume_attachment.this[count.index].iqn} -p ${oci_core_volume_attachment.this[count.index].ipv4}:${oci_core_volume_attachment.this[count.index].port}",
        "sudo iscsiadm -m node -o update -T ${oci_core_volume_attachment.this[count.index].iqn} -n node.startup -v automatic",
        "sudo iscsiadm -m node -T ${oci_core_volume_attachment.this[count.index].iqn} -p ${oci_core_volume_attachment.this[count.index].ipv4}:${oci_core_volume_attachment.this[count.index].port} -l",
        "sleep 5",
      ]) : "echo '>>> Paravirtualized attachment — no iSCSI setup needed.'",

      # Wait for the block device to appear
      "TIMEOUT=120",
      "ELAPSED=0",
      "DEVICE=''",
      "while [ -z \"$DEVICE\" ] && [ $ELAPSED -lt $TIMEOUT ]; do",
      "  # Look for the attached block volume device (typically /dev/sdb or /dev/oracleoci/oraclevd*)",
      "  for d in /dev/oracleoci/oraclevdb /dev/sdb /dev/xvdb /dev/vdb; do",
      "    if [ -b \"$d\" ]; then",
      "      DEVICE=\"$d\"",
      "      break",
      "    fi",
      "  done",
      "  if [ -z \"$DEVICE\" ]; then",
      "    echo \"  Waiting for block device... ($${ELAPSED}s elapsed)\"",
      "    sleep 5",
      "    ELAPSED=$((ELAPSED + 5))",
      "  fi",
      "done",

      "if [ -z \"$DEVICE\" ]; then",
      "  echo 'ERROR: Block volume device not found within timeout.'",
      "  lsblk",
      "  exit 1",
      "fi",
      "echo \">>> Block volume device found: $DEVICE\"",

      # Create filesystem and mount
      "sudo mkdir -p /mnt/fio-test",
      "if ! sudo blkid \"$DEVICE\" | grep -q 'TYPE='; then",
      "  echo '>>> Creating ext4 filesystem on block volume...'",
      "  sudo mkfs.ext4 -F \"$DEVICE\" 2>&1",
      "fi",
      "sudo mount \"$DEVICE\" /mnt/fio-test 2>/dev/null || sudo mount \"$DEVICE\" /mnt/fio-test",
      "sudo chmod 777 /mnt/fio-test",
      "echo \">>> Block volume mounted at /mnt/fio-test\"",
      "df -h /mnt/fio-test",

      # Save device info for later use
      "echo \"$DEVICE\" > /tmp/.fio-device",
    ]
  }

  depends_on = [
    null_resource.wait_for_cloud_init,
    oci_core_volume_attachment.this,
  ]
}

# -----------------------------------------------------------------------------
# FIO Benchmark
# -----------------------------------------------------------------------------
resource "null_resource" "fio_benchmark" {
  count = var.run_benchmark && var.run_fio && var.create_block_volumes ? var.instance_count : 0

  triggers = {
    benchmark_run_id = var.benchmark_run_id
    instance_id      = oci_core_instance.this[count.index].id
    bench_params = join("-", [
      var.fio_test_pattern,
      var.fio_block_size,
      var.fio_io_depth,
      var.fio_num_jobs,
      var.fio_duration,
      var.fio_file_size,
      var.fio_rwmixread,
      var.fio_direct ? "direct" : "buffered",
    ])
  }

  connection {
    type        = "ssh"
    host        = var.subnet_is_public && var.assign_public_ip ? oci_core_instance.this[count.index].public_ip : oci_core_instance.this[count.index].private_ip
    user        = local.ssh_user
    private_key = local.effective_ssh_private_key
    timeout     = "15m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo ''",
      "echo '╔══════════════════════════════════════════════════════════════╗'",
      "echo '║          FIO STORAGE I/O BENCHMARK                          ║'",
      "echo '╠══════════════════════════════════════════════════════════════╣'",
      "echo '║ Instance:    ${oci_core_instance.this[count.index].display_name}'",
      "echo '║ Shape:       ${var.instance_shape}'",
      "echo '║ BV Size:     ${var.block_volume_size_in_gbs} GB'",
      "echo '║ BV VPUs/GB:  ${var.block_volume_vpus_per_gb}'",
      "echo '║ Pattern:     ${var.fio_test_pattern}'",
      "echo '║ Block Size:  ${var.fio_block_size}'",
      "echo '║ I/O Depth:   ${var.fio_io_depth}'",
      "echo '║ Jobs:        ${var.fio_num_jobs == 0 ? "auto (nproc)" : var.fio_num_jobs}'",
      "echo '║ Duration:    ${var.fio_duration}s'",
      "echo '║ File Size:   ${var.fio_file_size}'",
      "echo '║ Direct I/O:  ${var.fio_direct ? "yes" : "no"}'",
      "echo '║ Run ID:      ${var.benchmark_run_id}'",
      "echo '╚══════════════════════════════════════════════════════════════╝'",
      "echo ''",

      # Verify fio is installed
      "if ! command -v fio >/dev/null 2>&1; then",
      "  echo 'ERROR: fio not found. Check /var/log/cloud-init-tools.log'",
      "  exit 1",
      "fi",
      "echo \"Using: fio $(fio --version)\"",
      "echo ''",

      # Verify mount point
      "if ! mountpoint -q /mnt/fio-test; then",
      "  echo 'ERROR: /mnt/fio-test is not mounted. Block volume may not be attached.'",
      "  exit 1",
      "fi",

      # Determine number of jobs
      "NUMJOBS=${var.fio_num_jobs}",
      "if [ \"$NUMJOBS\" -eq 0 ]; then NUMJOBS=$(nproc); echo \"Auto-detected jobs: $NUMJOBS\"; fi",

      # Build rwmixread flag (only for randrw)
      "RWMIX_FLAG=''",
      "if [ '${var.fio_test_pattern}' = 'randrw' ]; then RWMIX_FLAG='--rwmixread=${var.fio_rwmixread}'; fi",

      # Init FIO results file
      "FIO_RESULTS=/tmp/fio-benchmark-results.txt",
      "echo 'FIO BENCHMARK RESULTS' > $FIO_RESULTS",
      "echo \"Instance: ${oci_core_instance.this[count.index].display_name}\" >> $FIO_RESULTS",
      "echo \"Shape: ${var.instance_shape}\" >> $FIO_RESULTS",
      "echo \"BV Size: ${var.block_volume_size_in_gbs} GB | VPUs/GB: ${var.block_volume_vpus_per_gb}\" >> $FIO_RESULTS",
      "echo \"Run ID: ${var.benchmark_run_id}\" >> $FIO_RESULTS",
      "echo '' >> $FIO_RESULTS",

      # Run FIO benchmark
      "echo '>>> Running FIO benchmark: ${var.fio_test_pattern}...'",
      "echo ''",
      "fio --name=benchmark --directory=/mnt/fio-test --rw=${var.fio_test_pattern} --bs=${var.fio_block_size} --ioengine=libaio --iodepth=${var.fio_io_depth} --numjobs=$NUMJOBS --size=${var.fio_file_size} --runtime=${var.fio_duration} --time_based --group_reporting --direct=${var.fio_direct ? "1" : "0"} $RWMIX_FLAG --output=/tmp/fio-raw.txt --output-format=normal 2>&1",
      "cat /tmp/fio-raw.txt",

      # Extract key metrics from FIO output
      "echo '' >> $FIO_RESULTS",
      "echo '[FIO ${var.fio_test_pattern}] bs=${var.fio_block_size} | iodepth=${var.fio_io_depth} | jobs='$NUMJOBS' | ${var.fio_duration}s | direct=${var.fio_direct ? "1" : "0"}' >> $FIO_RESULTS",

      # Parse read metrics (if applicable)
      "if grep -q 'read:' /tmp/fio-raw.txt 2>/dev/null; then",
      "  READ_IOPS=$(grep ' read:' /tmp/fio-raw.txt | grep -oP 'IOPS=\\K[0-9.k]+' | head -1)",
      "  READ_BW=$(grep ' read:' /tmp/fio-raw.txt | grep -oP 'BW=\\K[0-9.]+[A-Za-z/]+' | head -1)",
      "  READ_LAT=$(grep -A5 'read:' /tmp/fio-raw.txt | grep 'avg=' | grep -oP 'avg=\\K[0-9.]+' | head -1)",
      "  echo \"  Read IOPS:       $READ_IOPS\" >> $FIO_RESULTS",
      "  echo \"  Read Bandwidth:  $READ_BW\" >> $FIO_RESULTS",
      "  echo \"  Read Lat avg:    $${READ_LAT}\" >> $FIO_RESULTS",
      "fi",

      # Parse write metrics (if applicable)
      "if grep -q 'write:' /tmp/fio-raw.txt 2>/dev/null; then",
      "  WRITE_IOPS=$(grep ' write:' /tmp/fio-raw.txt | grep -oP 'IOPS=\\K[0-9.k]+' | head -1)",
      "  WRITE_BW=$(grep ' write:' /tmp/fio-raw.txt | grep -oP 'BW=\\K[0-9.]+[A-Za-z/]+' | head -1)",
      "  WRITE_LAT=$(grep -A5 'write:' /tmp/fio-raw.txt | grep 'avg=' | grep -oP 'avg=\\K[0-9.]+' | head -1)",
      "  echo \"  Write IOPS:      $WRITE_IOPS\" >> $FIO_RESULTS",
      "  echo \"  Write Bandwidth: $WRITE_BW\" >> $FIO_RESULTS",
      "  echo \"  Write Lat avg:   $${WRITE_LAT}\" >> $FIO_RESULTS",
      "fi",

      # Also run a sequential read throughput test for reference
      "echo '' >> $FIO_RESULTS",
      "echo '>>> Running sequential read throughput baseline...'",
      "echo ''",
      "fio --name=seq-read --directory=/mnt/fio-test --rw=read --bs=1m --ioengine=libaio --iodepth=32 --numjobs=1 --size=${var.fio_file_size} --runtime=10 --time_based --group_reporting --direct=1 --output=/tmp/fio-seq-read.txt --output-format=normal 2>&1",
      "cat /tmp/fio-seq-read.txt",
      "SEQ_READ_BW=$(grep ' read:' /tmp/fio-seq-read.txt | grep -oP 'BW=\\K[0-9.]+[A-Za-z/]+' | head -1)",
      "SEQ_READ_IOPS=$(grep ' read:' /tmp/fio-seq-read.txt | grep -oP 'IOPS=\\K[0-9.k]+' | head -1)",
      "echo '[FIO Sequential Read Baseline] bs=1m | iodepth=32 | jobs=1 | 10s' >> $FIO_RESULTS",
      "echo \"  Seq Read BW:     $SEQ_READ_BW\" >> $FIO_RESULTS",
      "echo \"  Seq Read IOPS:   $SEQ_READ_IOPS\" >> $FIO_RESULTS",

      "echo ''",
      "echo 'FIO BENCHMARK COMPLETE: ${oci_core_instance.this[count.index].display_name}'",
    ]
  }

  depends_on = [null_resource.wait_for_block_volume]
}

# -----------------------------------------------------------------------------
# Collect FIO results — push to OCI Logging + print to RM apply logs
# -----------------------------------------------------------------------------
resource "null_resource" "fio_collect_results" {
  count = var.run_benchmark && var.run_fio && var.create_block_volumes ? var.instance_count : 0

  triggers = {
    benchmark_run_id = var.benchmark_run_id
    instance_id      = oci_core_instance.this[count.index].id
    bench_params = join("-", [
      var.fio_test_pattern,
      var.fio_block_size,
      var.fio_io_depth,
      var.fio_num_jobs,
      var.fio_duration,
    ])
  }

  connection {
    type        = "ssh"
    host        = var.subnet_is_public && var.assign_public_ip ? oci_core_instance.this[count.index].public_ip : oci_core_instance.this[count.index].private_ip
    user        = local.ssh_user
    private_key = local.effective_ssh_private_key
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo ''",
      "echo '================================================================'",
      "echo '  FIO RESULTS — ${oci_core_instance.this[count.index].display_name}'",
      "echo '================================================================'",
      "cat /tmp/fio-benchmark-results.txt 2>/dev/null || echo 'ERROR: FIO results file not found.'",
      "echo '================================================================'",
      "echo ''",

      # --- Push results to OCI Logging ---
      "echo '>>> Pushing FIO results to OCI Logging...'",

      "OCI_CLI=/usr/local/bin/oci",
      "if [ ! -x \"$OCI_CLI\" ]; then",
      "  echo 'WARNING: OCI CLI not found. Cannot push to OCI Logging.'",
      "  exit 0",
      "fi",

      "INSTANCE_NAME='${oci_core_instance.this[count.index].display_name}'",
      "RUN_ID='${var.benchmark_run_id}'",
      "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",

      "RESULTS_TEXT=$(cat /tmp/fio-benchmark-results.txt 2>/dev/null | sed 's/\\\\/\\\\\\\\/g' | sed 's/\"/\\\\\"/g' | sed ':a;N;$!ba;s/\\n/\\\\n/g')",

      "cat > /tmp/fio-log-batches.json <<EOF",
      "[",
      "  {",
      "    \"defaultlogentrytime\": \"$TIMESTAMP\",",
      "    \"source\": \"$INSTANCE_NAME\",",
      "    \"type\": \"com.oraclecloud.benchmark.fio\",",
      "    \"subject\": \"benchmark-run-$RUN_ID\",",
      "    \"entries\": [",
      "      {",
      "        \"data\": \"$RESULTS_TEXT\",",
      "        \"id\": \"fio-$INSTANCE_NAME-$RUN_ID-$(date +%s)\",",
      "        \"time\": \"$TIMESTAMP\"",
      "      }",
      "    ]",
      "  }",
      "]",
      "EOF",

      "if $OCI_CLI logging-ingestion put-logs --log-id '${var.run_benchmark && var.run_fio ? oci_logging_log.fio[0].id : ""}' --specversion '1.0' --log-entry-batches file:///tmp/fio-log-batches.json --auth instance_principal 2>&1; then",
      "  echo '>>> FIO results pushed to OCI Logging successfully.'",
      "else",
      "  echo 'WARNING: Failed to push FIO results to OCI Logging.'",
      "fi",
    ]
  }

  depends_on = [
    null_resource.fio_benchmark,
    oci_logging_log.fio,
  ]
}
