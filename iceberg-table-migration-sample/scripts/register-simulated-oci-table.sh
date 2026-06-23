#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

: "${OCI_ACCESS_KEY_ID:?Set OCI_ACCESS_KEY_ID}"
: "${OCI_SECRET_ACCESS_KEY:?Set OCI_SECRET_ACCESS_KEY}"

BUCKET="${BUCKET:-iceberg-table-demo}"
TABLE_PREFIX="${TABLE_PREFIX:-lakehouse/sales/orders}"
DATABASE="${DATABASE:-sales}"
TABLE="${TABLE:-orders}"
OCI_REGION="${OCI_REGION:-}"
OCI_CLI_AUTH="${OCI_CLI_AUTH:-instance_principal}"
VALIDATION_ENGINES="${VALIDATION_ENGINES:-spark}"

if [ -z "${OCI_S3_ENDPOINT:-}" ]; then
  : "${OCI_REGION:?Set OCI_REGION when OCI_S3_ENDPOINT is not set}"
  OCI_NAMESPACE="${OCI_NAMESPACE:-$(oci os ns get --auth instance_principal --query data --raw-output)}"
  OCI_S3_ENDPOINT="https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oci.customer-oci.com"
fi

OCI_ARGS=(--auth "${OCI_CLI_AUTH}")
if [ -n "${OCI_REGION}" ]; then
  OCI_ARGS+=(--region "${OCI_REGION}")
fi

LATEST_METADATA="$(
  oci "${OCI_ARGS[@]}" os object list \
    --bucket-name "${BUCKET}" \
    --prefix "${TABLE_PREFIX}/metadata/" \
    --fields name \
    --all \
    --query 'data[].name' \
    --output json |
    grep '\.metadata\.json' |
    tr -d '", ' |
    sed 's#^.*/##' |
    grep '^[0-9][0-9]*-.*\.metadata\.json$' |
    sort |
    tail -n 1 || true
)"

if [ -z "${LATEST_METADATA}" ]; then
  echo "No Iceberg metadata JSON found under s3://${BUCKET}/${TABLE_PREFIX}/metadata/"
  exit 1
fi

METADATA_FILE="s3://${BUCKET}/${TABLE_PREFIX}/metadata/${LATEST_METADATA}"

if [ "${CLEAN_TARGET_CATALOG:-true}" = "true" ]; then
  docker exec iceberg-hms-postgres psql -U hive -d metastore -v ON_ERROR_STOP=1 \
    -c "DELETE FROM iceberg_tables WHERE catalog_name = 'oci' AND table_namespace = '${DATABASE}' AND table_name = '${TABLE}';" \
    >/dev/null 2>&1 || true
fi

cat >/tmp/register-simulated-oci-table.sql <<SQL_EOF
CREATE NAMESPACE IF NOT EXISTS oci.${DATABASE};

CALL oci.system.register_table(
  table => '${DATABASE}.${TABLE}',
  metadata_file => '${METADATA_FILE}'
);

SHOW TABLES IN oci.${DATABASE};
DESCRIBE oci.${DATABASE}.${TABLE};
SELECT COUNT(*) AS row_count FROM oci.${DATABASE}.${TABLE};
SQL_EOF

/opt/iceberg/spark-sql-oci.sh -f /tmp/register-simulated-oci-table.sql

if [[ ",${VALIDATION_ENGINES}," == *",trino,"* ]]; then
  /opt/iceberg/validate-with-trino.sh
fi

echo "Registered table: oci.${DATABASE}.${TABLE}"
echo "Metadata file: ${METADATA_FILE}"
