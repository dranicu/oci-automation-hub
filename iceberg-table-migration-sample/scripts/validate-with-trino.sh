#!/bin/bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/

set -euo pipefail

: "${OCI_ACCESS_KEY_ID:?Set OCI_ACCESS_KEY_ID}"
: "${OCI_SECRET_ACCESS_KEY:?Set OCI_SECRET_ACCESS_KEY}"

BUCKET="${BUCKET:-iceberg-table-demo}"
DATABASE="${DATABASE:-sales}"
TABLE="${TABLE:-orders}"
TRINO_IMAGE="${TRINO_IMAGE:-trinodb/trino:latest}"
TRINO_CONTAINER="${TRINO_CONTAINER:-iceberg-trino}"
JDBC_CATALOG_URI="${JDBC_CATALOG_URI:-jdbc:postgresql://127.0.0.1:5432/metastore}"
JDBC_CATALOG_USER="${JDBC_CATALOG_USER:-hive}"
JDBC_CATALOG_PASSWORD="${JDBC_CATALOG_PASSWORD:-hive}"
OCI_REGION="${OCI_REGION:-}"

if [ -z "${OCI_S3_ENDPOINT:-}" ]; then
  : "${OCI_REGION:?Set OCI_REGION when OCI_S3_ENDPOINT is not set}"
  OCI_NAMESPACE="${OCI_NAMESPACE:-$(oci os ns get --auth instance_principal --query data --raw-output)}"
  OCI_S3_ENDPOINT="https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oci.customer-oci.com"
fi

mkdir -p /opt/iceberg/trino/catalog
cat >/opt/iceberg/trino/catalog/iceberg.properties <<TRINO_CATALOG_EOF
connector.name=iceberg
iceberg.catalog.type=jdbc
iceberg.jdbc-catalog.driver-class=org.postgresql.Driver
iceberg.jdbc-catalog.connection-url=${JDBC_CATALOG_URI}
iceberg.jdbc-catalog.connection-user=${JDBC_CATALOG_USER}
iceberg.jdbc-catalog.connection-password=${JDBC_CATALOG_PASSWORD}
iceberg.jdbc-catalog.catalog-name=oci
iceberg.jdbc-catalog.default-warehouse-dir=s3://${BUCKET}/lakehouse
iceberg.security=ALLOW_ALL
fs.native-s3.enabled=true
s3.endpoint=${OCI_S3_ENDPOINT}
s3.region=${OCI_REGION}
s3.path-style-access=true
s3.aws-access-key=${OCI_ACCESS_KEY_ID}
s3.aws-secret-key=${OCI_SECRET_ACCESS_KEY}
TRINO_CATALOG_EOF

docker rm -f "${TRINO_CONTAINER}" >/dev/null 2>&1 || true
docker run -d \
  --name "${TRINO_CONTAINER}" \
  --network host \
  -v /opt/iceberg/trino/catalog:/etc/trino/catalog:ro \
  "${TRINO_IMAGE}" >/dev/null

until curl -sf http://127.0.0.1:8080/v1/info >/dev/null; do
  echo "Waiting for Trino..."
  sleep 2
done

until docker exec "${TRINO_CONTAINER}" trino --execute "SELECT 1" >/dev/null 2>&1; do
  echo "Waiting for Trino coordinator..."
  sleep 3
done

docker exec "${TRINO_CONTAINER}" trino --execute "
SHOW TABLES FROM iceberg.${DATABASE};
DESCRIBE iceberg.${DATABASE}.${TABLE};
SELECT COUNT(*) AS row_count FROM iceberg.${DATABASE}.${TABLE};
"

echo "Trino validated table: iceberg.${DATABASE}.${TABLE}"
