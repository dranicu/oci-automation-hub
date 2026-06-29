#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

BUCKET="${BUCKET:-iceberg-table-demo}"
TABLE_PREFIX="${TABLE_PREFIX:-lakehouse/sales/orders}"
EXPORT_ROOT="${EXPORT_ROOT:-/opt/iceberg/generated_aws_source}"
SOURCE_DIR="${SOURCE_DIR:-${EXPORT_ROOT}/${BUCKET}/${TABLE_PREFIX}}"
OCI_REGION="${OCI_REGION:-}"
OCI_CLI_AUTH="${OCI_CLI_AUTH:-instance_principal}"

if [ ! -d "${SOURCE_DIR}" ]; then
  echo "Missing source directory: ${SOURCE_DIR}"
  echo "Run generate-simulated-aws-iceberg-table.sh first, or set SOURCE_DIR to a local exported Iceberg table."
  exit 1
fi

OCI_ARGS=(--auth "${OCI_CLI_AUTH}")
if [ -n "${OCI_REGION}" ]; then
  OCI_ARGS+=(--region "${OCI_REGION}")
fi

oci "${OCI_ARGS[@]}" os object bulk-delete \
  --bucket-name "${BUCKET}" \
  --prefix "${TABLE_PREFIX}/" \
  --force || true

oci "${OCI_ARGS[@]}" os object sync \
  --bucket-name "${BUCKET}" \
  --src-dir "${SOURCE_DIR}" \
  --prefix "${TABLE_PREFIX}/"

echo "Copied local Iceberg source into OCI Object Storage:"
echo "Source directory: ${SOURCE_DIR}"
echo "s3://${BUCKET}/${TABLE_PREFIX}/"
