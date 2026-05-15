# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

# =============================================================================
# CPU Benchmark — sysbench (open-source)
#
# Flow:
#   1. wait_for_cloud_init  → polls until sysbench is installed
#   2. cpu_benchmark        → runs sysbench, saves summary to /tmp/benchmark-results.txt
#   3. memory_benchmark     → optional, appends to results file
#   4. collect_results      → reads results file back via SSH, outputs to RM logs
#
# The collect_results resource SSHs back in after benchmarks complete and
# cats the results file. This output appears both in RM apply logs AND
# is printed at the end of the apply, making it easy to find.
# =============================================================================

# -----------------------------------------------------------------------------
# Wait for cloud-init to finish and sysbench to be installed
# -----------------------------------------------------------------------------
resource "null_resource" "wait_for_cloud_init" {
  count = local.any_benchmark_enabled ? var.instance_count : 0

  triggers = {
    instance_id = oci_core_instance.this[count.index].id
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
      "echo '>>> Waiting for cloud-init to complete on ${oci_core_instance.this[count.index].display_name}...'",
      "TIMEOUT=600",
      "ELAPSED=0",
      "while [ ! -f /var/lib/cloud/instance/boot-finished ] && [ $ELAPSED -lt $TIMEOUT ]; do",
      "  echo \"  cloud-init still running... ($${ELAPSED}s elapsed)\"",
      "  sleep 10",
      "  ELAPSED=$((ELAPSED + 10))",
      "done",
      "if [ ! -f /var/lib/cloud/instance/boot-finished ]; then",
      "  echo 'ERROR: cloud-init did not finish within timeout.'",
      "  exit 1",
      "fi",
      "echo '>>> cloud-init finished.'",
      "TIMEOUT=120",
      "ELAPSED=0",
      "while [ ! -f /tmp/.sysbench-ready ] && [ $ELAPSED -lt $TIMEOUT ]; do",
      "  echo \"  waiting for sysbench marker... ($${ELAPSED}s elapsed)\"",
      "  sleep 5",
      "  ELAPSED=$((ELAPSED + 5))",
      "done",
      "if command -v sysbench >/dev/null 2>&1; then",
      "  echo \">>> sysbench ready: $(sysbench --version)\"",
      "elif [ -x /usr/local/bin/sysbench ]; then",
      "  echo \">>> sysbench ready: $(/usr/local/bin/sysbench --version)\"",
      "else",
      "  echo 'ERROR: sysbench not found after cloud-init. Check /var/log/cloud-init-tools.log'",
      "  cat /var/log/cloud-init-tools.log 2>/dev/null || true",
      "  exit 1",
      "fi",
      "if command -v fio >/dev/null 2>&1; then",
      "  echo \">>> fio ready: $(fio --version)\"",
      "else",
      "  echo 'WARNING: fio not found. FIO benchmarks will not be available.'",
      "fi",
      "if [ -x /usr/local/bin/oci ]; then",
      "  echo \">>> OCI CLI ready: $(/usr/local/bin/oci --version 2>&1)\"",
      "else",
      "  echo 'WARNING: OCI CLI not found. Benchmark results will not be pushed to OCI Logging.'",
      "fi",
    ]
  }

  depends_on = [oci_core_instance.this]
}

# -----------------------------------------------------------------------------
# CPU Benchmark
# -----------------------------------------------------------------------------
resource "null_resource" "cpu_benchmark" {
  count = var.run_benchmark && var.run_sysbench ? var.instance_count : 0

  triggers = {
    benchmark_run_id = var.benchmark_run_id
    instance_id      = oci_core_instance.this[count.index].id
    bench_params = join("-", [
      var.sysbench_threads,
      var.sysbench_cpu_max_prime,
      var.sysbench_duration,
      var.sysbench_events
    ])
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
      "echo ''",
      "echo '╔══════════════════════════════════════════════════════════════╗'",
      "echo '║          SYSBENCH CPU BENCHMARK                             ║'",
      "echo '╠══════════════════════════════════════════════════════════════╣'",
      "echo '║ Instance:  ${oci_core_instance.this[count.index].display_name}'",
      "echo '║ Shape:     ${var.instance_shape}'",
      "echo '║ OCPUs:     ${local.is_flex_shape ? var.instance_flex_ocpus : "fixed"}'",
      "echo '║ Threads:   ${var.sysbench_threads == 0 ? "auto (nproc)" : var.sysbench_threads}'",
      "echo '║ Max Prime: ${var.sysbench_cpu_max_prime}'",
      "echo '║ Duration:  ${var.sysbench_duration}s'",
      "echo '║ Events:    ${var.sysbench_events == 0 ? "unlimited" : var.sysbench_events}'",
      "echo '║ Run ID:    ${var.benchmark_run_id}'",
      "echo '╚══════════════════════════════════════════════════════════════╝'",
      "echo ''",

      # Resolve sysbench path
      "SYSBENCH=$(command -v sysbench || echo /usr/local/bin/sysbench)",
      "echo \"Using: $SYSBENCH ($($SYSBENCH --version))\"",
      "echo ''",

      # Determine thread count
      "THREADS=${var.sysbench_threads}",
      "if [ \"$THREADS\" -eq 0 ]; then THREADS=$(nproc); echo \"Auto-detected threads: $THREADS\"; fi",

      # Build events flag
      "EVENTS_FLAG=''",
      "if [ ${var.sysbench_events} -gt 0 ]; then EVENTS_FLAG='--events=${var.sysbench_events}'; fi",

      # Init results file — plain text for clean log output
      "RESULTS_FILE=/tmp/benchmark-results.txt",
      "echo 'BENCHMARK RESULTS' > $RESULTS_FILE",
      "echo \"Instance: ${oci_core_instance.this[count.index].display_name}\" >> $RESULTS_FILE",
      "echo \"Shape: ${var.instance_shape}\" >> $RESULTS_FILE",
      "echo \"OCPUs: ${local.is_flex_shape ? var.instance_flex_ocpus : "fixed"}\" >> $RESULTS_FILE",
      "echo \"Run ID: ${var.benchmark_run_id}\" >> $RESULTS_FILE",
      "echo '' >> $RESULTS_FILE",

      # Run multi-thread CPU benchmark
      "echo '>>> Running multi-thread CPU benchmark...'",
      "echo ''",
      "$SYSBENCH cpu --threads=$THREADS --cpu-max-prime=${var.sysbench_cpu_max_prime} --time=${var.sysbench_duration} $EVENTS_FLAG run 2>&1 | tee /tmp/cpu-bench-mt.txt",

      # Extract and write multi-thread results
      "echo '[CPU Multi-Thread] threads='$THREADS' | prime=${var.sysbench_cpu_max_prime} | ${var.sysbench_duration}s' >> $RESULTS_FILE",
      "MT_EPS=$(grep 'events per second' /tmp/cpu-bench-mt.txt | awk '{print $NF}')",
      "MT_EVENTS=$(grep 'total number of events' /tmp/cpu-bench-mt.txt | awk '{print $NF}')",
      "MT_LATAVG=$(grep 'avg:' /tmp/cpu-bench-mt.txt | awk '{print $NF}')",
      "MT_LAT95=$(grep '95th percentile:' /tmp/cpu-bench-mt.txt | awk '{print $NF}')",
      "MT_LATMIN=$(grep 'min:' /tmp/cpu-bench-mt.txt | awk '{print $NF}')",
      "MT_LATMAX=$(grep 'max:' /tmp/cpu-bench-mt.txt | awk '{print $NF}')",
      "echo \"  Events/sec:      $MT_EPS\" >> $RESULTS_FILE",
      "echo \"  Total events:    $MT_EVENTS\" >> $RESULTS_FILE",
      "echo \"  Latency avg:     $${MT_LATAVG}ms\" >> $RESULTS_FILE",
      "echo \"  Latency 95th:    $${MT_LAT95}ms\" >> $RESULTS_FILE",
      "echo \"  Latency min/max: $${MT_LATMIN}ms / $${MT_LATMAX}ms\" >> $RESULTS_FILE",
      "echo '' >> $RESULTS_FILE",

      # Run single-thread baseline
      "echo ''",
      "echo '>>> Running single-thread baseline...'",
      "echo ''",
      "$SYSBENCH cpu --threads=1 --cpu-max-prime=20000 --time=10 run 2>&1 | tee /tmp/cpu-bench-st.txt",

      # Extract and write single-thread results
      "echo '[CPU Single-Thread] threads=1 | prime=20000 | 10s' >> $RESULTS_FILE",
      "ST_EPS=$(grep 'events per second' /tmp/cpu-bench-st.txt | awk '{print $NF}')",
      "ST_LATAVG=$(grep 'avg:' /tmp/cpu-bench-st.txt | awk '{print $NF}')",
      "ST_LAT95=$(grep '95th percentile:' /tmp/cpu-bench-st.txt | awk '{print $NF}')",
      "echo \"  Events/sec:      $ST_EPS\" >> $RESULTS_FILE",
      "echo \"  Latency avg:     $${ST_LATAVG}ms\" >> $RESULTS_FILE",
      "echo \"  Latency 95th:    $${ST_LAT95}ms\" >> $RESULTS_FILE",

      "echo ''",
      "echo 'CPU BENCHMARK COMPLETE: ${oci_core_instance.this[count.index].display_name}'",
    ]
  }

  depends_on = [null_resource.wait_for_cloud_init]
}

# -----------------------------------------------------------------------------
# Optional: Memory benchmark — appends to results file
# -----------------------------------------------------------------------------
resource "null_resource" "memory_benchmark" {
  count = var.run_benchmark && var.run_sysbench && var.run_memory_benchmark ? var.instance_count : 0

  triggers = {
    benchmark_run_id = var.benchmark_run_id
    instance_id      = oci_core_instance.this[count.index].id
    bench_params     = join("-", [var.sysbench_threads, var.sysbench_memory_block_size, var.sysbench_memory_total_size])
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
      "echo ''",
      "echo '╔══════════════════════════════════════════════════════════════╗'",
      "echo '║          SYSBENCH MEMORY BENCHMARK                          ║'",
      "echo '╚══════════════════════════════════════════════════════════════╝'",
      "echo ''",

      "SYSBENCH=$(command -v sysbench || echo /usr/local/bin/sysbench)",
      "THREADS=${var.sysbench_threads}",
      "if [ \"$THREADS\" -eq 0 ]; then THREADS=$(nproc); fi",
      "RESULTS_FILE=/tmp/benchmark-results.txt",

      "$SYSBENCH memory --threads=$THREADS --memory-block-size=${var.sysbench_memory_block_size} --memory-total-size=${var.sysbench_memory_total_size} run 2>&1 | tee /tmp/mem-bench-raw.txt",

      # Append memory results
      "echo '' >> $RESULTS_FILE",
      "echo '[Memory Bandwidth] block=${var.sysbench_memory_block_size} | total=${var.sysbench_memory_total_size} | threads='$THREADS >> $RESULTS_FILE",
      "MEM_THROUGHPUT=$(grep 'transferred' /tmp/mem-bench-raw.txt | grep -oP '[\\d.]+\\s+MiB/sec' || echo 'N/A')",
      "MEM_OPS=$(grep 'total number of events' /tmp/mem-bench-raw.txt | awk '{print $NF}')",
      "MEM_LATAVG=$(grep 'avg:' /tmp/mem-bench-raw.txt | awk '{print $NF}')",
      "MEM_LAT95=$(grep '95th percentile:' /tmp/mem-bench-raw.txt | awk '{print $NF}')",
      "echo \"  Throughput:      $MEM_THROUGHPUT\" >> $RESULTS_FILE",
      "echo \"  Total ops:       $MEM_OPS\" >> $RESULTS_FILE",
      "echo \"  Latency avg:     $${MEM_LATAVG}ms\" >> $RESULTS_FILE",
      "echo \"  Latency 95th:    $${MEM_LAT95}ms\" >> $RESULTS_FILE",

      "echo ''",
      "echo 'MEMORY BENCHMARK COMPLETE: ${oci_core_instance.this[count.index].display_name}'",
    ]
  }

  depends_on = [null_resource.cpu_benchmark]
}

# -----------------------------------------------------------------------------
# Collect results — push to OCI Logging + print to RM apply logs
#
# Uses the OCI CLI on the instance with Instance Principal auth to push
# the benchmark results to the Custom Log created in logging.tf.
# All instances log to the same Log Group, so you get a single unified
# view in OCI Console → Observability → Logging → Log Search.
# -----------------------------------------------------------------------------
resource "null_resource" "collect_results" {
  count = var.run_benchmark && var.run_sysbench ? var.instance_count : 0

  triggers = {
    benchmark_run_id = var.benchmark_run_id
    instance_id      = oci_core_instance.this[count.index].id
    bench_params = join("-", [
      var.sysbench_threads,
      var.sysbench_cpu_max_prime,
      var.sysbench_duration,
      var.sysbench_events,
      var.run_memory_benchmark ? "mem" : "nomem"
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
      "echo '  FINAL RESULTS — ${oci_core_instance.this[count.index].display_name}'",
      "echo '================================================================'",
      "cat /tmp/benchmark-results.txt 2>/dev/null || echo 'ERROR: Results file not found.'",
      "echo '================================================================'",
      "echo ''",

      # --- Push results to OCI Logging ---
      "echo '>>> Pushing results to OCI Logging...'",

      # Use the system-wide symlink created by cloud-init
      "OCI_CLI=/usr/local/bin/oci",
      "if [ ! -x \"$OCI_CLI\" ]; then",
      "  echo 'WARNING: OCI CLI not found at /usr/local/bin/oci. Cannot push to OCI Logging.'",
      "  echo 'Results are still available in /tmp/benchmark-results.txt'",
      "  exit 0",
      "fi",
      "echo \"Using OCI CLI: $($OCI_CLI --version 2>&1)\"",

      # Prepare variables
      "INSTANCE_NAME='${oci_core_instance.this[count.index].display_name}'",
      "RUN_ID='${var.benchmark_run_id}'",
      "TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)",

      # Read results and escape for JSON (newlines and quotes)
      "RESULTS_TEXT=$(cat /tmp/benchmark-results.txt 2>/dev/null | sed 's/\\\\/\\\\\\\\/g' | sed 's/\"/\\\\\"/g' | sed ':a;N;$!ba;s/\\n/\\\\n/g')",

      # Build the --log-entry-batches JSON
      "cat > /tmp/log-batches.json <<EOF",
      "[",
      "  {",
      "    \"defaultlogentrytime\": \"$TIMESTAMP\",",
      "    \"source\": \"$INSTANCE_NAME\",",
      "    \"type\": \"com.oraclecloud.benchmark.sysbench\",",
      "    \"subject\": \"benchmark-run-$RUN_ID\",",
      "    \"entries\": [",
      "      {",
      "        \"data\": \"$RESULTS_TEXT\",",
      "        \"id\": \"bench-$INSTANCE_NAME-$RUN_ID-$(date +%s)\",",
      "        \"time\": \"$TIMESTAMP\"",
      "      }",
      "    ]",
      "  }",
      "]",
      "EOF",

      # Push to OCI Logging using Instance Principal auth
      "if $OCI_CLI logging-ingestion put-logs --log-id '${var.run_benchmark && var.run_sysbench ? oci_logging_log.benchmark[0].id : ""}' --specversion '1.0' --log-entry-batches file:///tmp/log-batches.json --auth instance_principal 2>&1; then",
      "  echo '>>> Results pushed to OCI Logging successfully.'",
      "  echo '>>> View at: OCI Console > Observability & Management > Logging > Log Search'",
      "  echo '>>> Log Group: ${var.resource_name_prefix}-benchmark-logs'",
      "else",
      "  echo 'WARNING: Failed to push to OCI Logging. Results are still in /tmp/benchmark-results.txt'",
      "  echo 'This may be due to IAM policy propagation delay. Try again in a few minutes.'",
      "fi",
    ]
  }

  depends_on = [
    null_resource.cpu_benchmark,
    null_resource.memory_benchmark,
    oci_logging_log.benchmark,
  ]
}
