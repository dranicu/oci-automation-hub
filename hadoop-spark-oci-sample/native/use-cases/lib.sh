#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Shared helpers for the use-case scripts. Sourced (not executed) by each
# use case's run.sh / submit.sh.
#
# It loads deployment.env — a descriptor Terraform writes onto the operator VM
# that records what the stack actually deployed — so a use case can refuse to
# run (with a clear message) when its prerequisites aren't present, instead of
# failing with an opaque OCI error.
###############################################################################

# Locate and source deployment.env. Written to /home/opc/use-cases by the
# operator's cloud-init; also lives next to these scripts when pulled from the
# bucket. Fall back to the directory this library sits in.
_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _env in "$_lib_dir/deployment.env" "/home/opc/use-cases/deployment.env"; do
  if [ -f "$_env" ]; then
    # shellcheck disable=SC1090
    . "$_env"
    DEPLOYMENT_ENV_FILE="$_env"
    break
  fi
done

# All OCI CLI calls from the operator use instance-principal auth (no keys).
export OCI_CLI_AUTH="${OCI_CLI_AUTH:-instance_principal}"

_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
_yel()  { printf '\033[33m%s\033[0m\n' "$*"; }
_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }

# Fail with a message that names the Resource Manager form field to change.
_cannot_run() {
  echo
  _red "This use case can't run on the current deployment."
  echo "  $1"
  echo
  echo "Re-apply the Resource Manager stack with the setting above, then retry."
  exit 1
}

require_deployment_env() {
  if [ -z "${DEPLOYMENT_ENV_FILE:-}" ]; then
    _red "deployment.env not found."
    echo "Expected it next to these scripts or at /home/opc/use-cases/deployment.env."
    echo "It is written by the operator VM's cloud-init — are you running this on the operator?"
    exit 1
  fi
}

require_dataflow() {
  require_deployment_env
  [ "${DEPLOY_DATAFLOW:-false}" = "true" ] || \
    _cannot_run "Data Flow is not deployed. Set 'Deploy Data Flow (Spark) applications' = on."
}

require_bds() {
  require_deployment_env
  [ "${DEPLOY_BDS:-false}" = "true" ] || \
    _cannot_run "Big Data Service is not deployed. Set 'Deploy Big Data Service (Hadoop)' = on."
}

require_scripts_bucket() {
  require_deployment_env
  [ -n "${SCRIPTS_BUCKET:-}" ] || \
    _cannot_run "No scripts bucket. Set 'Create scripts bucket' = on (under Data Flow)."
}

require_warehouse_bucket() {
  require_deployment_env
  [ -n "${WAREHOUSE_BUCKET:-}" ] || \
    _cannot_run "No warehouse bucket. Set 'Create warehouse bucket' = on (under Data Flow)."
}

# Use case 04 expects a secure, highly-available cluster. Warn (don't fail) when
# the deployed cluster isn't secure/HA, so the Kerberos steps make sense.
require_bds_secure_ha() {
  require_bds
  if [ "${BDS_SECURE:-false}" != "true" ]; then
    _yel "Note: this cluster is NOT secure (no Kerberos/Ranger). The kinit steps"
    _yel "won't apply. Re-apply with 'Secure cluster (Kerberos + Ranger)' = on."
  fi
  if [ "${BDS_HIGH_AVAILABILITY:-false}" != "true" ]; then
    _yel "Note: this cluster is NOT highly available (single master + utility)."
    _yel "Re-apply with 'High availability' = on for the production shape."
  fi
}

# Warm pool is an optimization, not a hard requirement — warn, don't fail.
require_warm_pool() {
  if [ "${DATAFLOW_CREATE_POOL:-false}" != "true" ] || [ -z "${DATAFLOW_POOL_ID:-}" ]; then
    _yel "Note: no Data Flow warm pool is deployed — runs will cold-start (~1 min)."
    _yel "To get fast starts, re-apply with 'Create a Data Flow warm pool' = on."
  fi
}

# Upload a local file to the scripts bucket. Usage: put_script <local_path> [object_name]
put_script() {
  local src="$1" name="${2:-$(basename "$1")}"
  echo "Uploading $name to oci://$SCRIPTS_BUCKET@$OS_NAMESPACE/$name"
  oci os object put \
    --namespace "$OS_NAMESPACE" \
    --bucket-name "$SCRIPTS_BUCKET" \
    --name "$name" \
    --file "$src" \
    --force >/dev/null
}

# Idempotently ensure a Data Flow application exists, echo its OCID.
# Usage: ensure_dataflow_app <display_name> <language> <spark_version> <file_uri> \
#                            <num_executors> <driver_ocpus> <driver_mem> \
#                            <executor_ocpus> <executor_mem>
ensure_dataflow_app() {
  local name="$1" lang="$2" sver="$3" file_uri="$4"
  local num_exec="${5:-2}" d_ocpus="${6:-1}" d_mem="${7:-16}" e_ocpus="${8:-2}" e_mem="${9:-16}"

  # Reuse an existing application with this display name if one is already there
  # (data-flow application list has no --lifecycle-state flag; --display-name is
  # an exact server-side filter).
  local existing
  existing=$(oci data-flow application list \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$name" \
    --query 'data[0].id' --raw-output 2>/dev/null || true)

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "$existing"
    return 0
  fi

  # Optional extras: warm pool, and logs/warehouse buckets so runs have a place
  # to write (mirrors how the Terraform-created applications are configured).
  local extra_args=()
  [ -n "${DATAFLOW_POOL_ID:-}" ] && extra_args+=(--pool-id "$DATAFLOW_POOL_ID")
  [ -n "${LOGS_BUCKET:-}" ] && extra_args+=(--logs-bucket-uri "oci://$LOGS_BUCKET@$OS_NAMESPACE/")
  [ -n "${WAREHOUSE_BUCKET:-}" ] && extra_args+=(--warehouse-bucket-uri "oci://$WAREHOUSE_BUCKET@$OS_NAMESPACE/")

  oci data-flow application create \
    --compartment-id "$COMPARTMENT_OCID" \
    --display-name "$name" \
    --language "$lang" \
    --spark-version "$sver" \
    --file-uri "$file_uri" \
    --num-executors "$num_exec" \
    --driver-shape "VM.Standard.E4.Flex" \
    --executor-shape "VM.Standard.E4.Flex" \
    --driver-shape-config "{\"ocpus\": $d_ocpus, \"memoryInGBs\": $d_mem}" \
    --executor-shape-config "{\"ocpus\": $e_ocpus, \"memoryInGBs\": $e_mem}" \
    --type BATCH \
    "${extra_args[@]}" \
    --query 'data.id' --raw-output
}

# When a run is submitted against a warm pool, its driver/executor shape config
# must MATCH a shape configuration the pool provides — otherwise Data Flow
# rejects the run ("shape configuration not found in pool"). Populate a
# POOL_RUN_ARGS array with the pool's shape so the run create lands on it. Safe
# to call when there is no pool (leaves the array empty).
build_pool_run_args() {
  POOL_RUN_ARGS=()
  [ -n "${DATAFLOW_POOL_ID:-}" ] || return 0

  local shape ocpus mem
  shape=$(oci data-flow pool get --pool-id "$DATAFLOW_POOL_ID" \
    --query 'data.configurations[0].shape' --raw-output 2>/dev/null || true)
  [ -n "$shape" ] && [ "$shape" != "null" ] || return 0

  ocpus=$(oci data-flow pool get --pool-id "$DATAFLOW_POOL_ID" \
    --query 'data.configurations[0]."shape-config".ocpus' --raw-output 2>/dev/null || true)
  mem=$(oci data-flow pool get --pool-id "$DATAFLOW_POOL_ID" \
    --query 'data.configurations[0]."shape-config"."memory-in-gbs"' --raw-output 2>/dev/null || true)

  POOL_RUN_ARGS=(--driver-shape "$shape" --executor-shape "$shape")
  if [ -n "$ocpus" ] && [ "$ocpus" != "null" ]; then
    POOL_RUN_ARGS+=(
      --driver-shape-config "{\"ocpus\": $ocpus, \"memoryInGBs\": $mem}"
      --executor-shape-config "{\"ocpus\": $ocpus, \"memoryInGBs\": $mem}"
    )
  fi
  echo "Matching run to warm-pool shape: $shape (${ocpus} OCPU / ${mem} GB)"
}

# Echo the OCID of the first ACTIVE BDS cluster in the compartment (empty if
# none). Filters client-side and tolerates either CLI response shape
# (data.items[] or a bare data[] array).
bds_active_cluster_id() {
  local id
  id=$(oci bds instance list --compartment-id "$COMPARTMENT_OCID" --all \
    --query 'data.items[?"lifecycle-state"==`ACTIVE`].id | [0]' --raw-output 2>/dev/null || true)
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    id=$(oci bds instance list --compartment-id "$COMPARTMENT_OCID" --all \
      --query 'data[?"lifecycle-state"==`ACTIVE`].id | [0]' --raw-output 2>/dev/null || true)
  fi
  [ "$id" = "null" ] && id=""
  echo "$id"
}

# Print a table of every BDS cluster and its state (for "not ready yet" hints).
bds_cluster_states() {
  oci bds instance list --compartment-id "$COMPARTMENT_OCID" --all \
    --query 'data.items[].{name:"display-name",state:"lifecycle-state"}' --output table 2>/dev/null \
    || oci bds instance list --compartment-id "$COMPARTMENT_OCID" --all \
    --query 'data[].{name:"display-name",state:"lifecycle-state"}' --output table 2>/dev/null || true
}

# Echo the private IP of the first node of a given type (UTILITY | MASTER).
bds_node_ip() {
  local bds_id="$1" ntype="$2" ip
  ip=$(oci bds instance get --bds-instance-id "$bds_id" \
    --query "data.nodes[?\"node-type\"==\`$ntype\`].\"ip-address\" | [0]" --raw-output 2>/dev/null || true)
  [ "$ip" = "null" ] && ip=""
  echo "$ip"
}

# Convenience: oci:// URI for an object in a given bucket.
os_uri() { echo "oci://$2@$OS_NAMESPACE/$1"; }
