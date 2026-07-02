#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Use case 02 — Hadoop cluster analytics. Run this ON the operator VM.
#
# spark-submit has to run ON a BDS node, and SSH from the operator to BDS needs
# YOUR private key (we never place private keys on the operator). So this script
# self-checks that BDS is deployed, resolves the cluster's node IPs for you, and
# prints the exact steps to copy the job over and run it on the cluster.
###############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

require_bds

echo "Resolving the BDS cluster in compartment $COMPARTMENT_OCID ..."
BDS_ID="$(bds_active_cluster_id)"

if [ -z "$BDS_ID" ]; then
  _yel "BDS is enabled but no ACTIVE cluster was found. Current clusters:"
  bds_cluster_states
  _yel "If a cluster is still CREATING, wait for it to reach ACTIVE and retry."
  exit 1
fi

UTIL_IP="$(bds_node_ip "$BDS_ID" UTILITY)"
MASTER_IP="$(bds_node_ip "$BDS_ID" MASTER)"

_grn "Cluster:      $BDS_ID"
_grn "Utility node: ${UTIL_IP:-<unknown>}"
_grn "Master node:  ${MASTER_IP:-<unknown>}"

TARGET_IP="${UTIL_IP:-$MASTER_IP}"

if [ "${BDS_SECURE:-false}" = "true" ]; then
  cat <<EOF

⚠ This is a SECURE (Kerberos) cluster. HDFS/YARN reject every command that has no
Kerberos ticket ("Client cannot authenticate via:[TOKEN, KERBEROS]"). This use
case is written for a NON-secure cluster — on this one you must \`kinit\` first.
(A secure + HA cluster is the use case 04 shape.)

Quickest path — run the job as the hdfs superuser (fine for a demo). First copy
the files to a world-readable path so the hdfs user can read them:

  scp $HERE/sales_report.py $HERE/sales.csv opc@$TARGET_IP:/tmp/
  ssh opc@$TARGET_IP
EOF
  # Quoted heredoc: these commands are printed verbatim (no local expansion).
  cat <<'EOF'
  # --- on the BDS node ---
  # find an hdfs keytab (adjust if the name differs: sudo ls /etc/security/keytabs/)
  KT=$(sudo bash -c 'ls /etc/security/keytabs/*hdfs*.keytab 2>/dev/null' | head -1)
  PRINC=$(sudo klist -kt "$KT" | awk 'NR>3{print $4; exit}')
  sudo -u hdfs kinit -kt "$KT" "$PRINC" && sudo -u hdfs klist   # confirm the ticket

  sudo -u hdfs hdfs dfs -mkdir -p /user/hdfs/sales
  sudo -u hdfs hdfs dfs -put -f /tmp/sales.csv /user/hdfs/sales/
  sudo -u hdfs spark-submit --master yarn --deploy-mode cluster \
    --num-executors 3 --executor-cores 4 --executor-memory 8g \
    /tmp/sales_report.py \
    hdfs:///user/hdfs/sales/sales.csv hdfs:///user/hdfs/sales_report
  sudo -u hdfs hdfs dfs -cat /user/hdfs/sales_report/part-*.csv
EOF
  cat <<EOF

To run as your OWN user instead, create a Kerberos principal on the master node
(\`sudo kadmin.local\` then \`addprinc opc\`) and \`kinit opc\` — this needs the
cluster/KDC admin credentials; see the OCI Big Data Service docs on secure
clusters. Or, to use the plain non-Kerberos flow, redeploy with 'Secure cluster'
OFF (that's the intended use case 02 configuration).
EOF
  exit 0
fi

cat <<EOF

The operator can reach those private IPs. Run the job from here like this
(use SSH agent forwarding so your key reaches the BDS node — connect to the
operator with 'ssh -A'):

  # 1. Copy the job + data from the operator to the BDS node:
  scp $HERE/sales_report.py $HERE/sales.csv opc@$TARGET_IP:/home/opc/

  # 2. On the BDS node, load the CSV into HDFS and submit on YARN:
  ssh opc@$TARGET_IP '
    hdfs dfs -mkdir -p /user/opc/sales &&
    hdfs dfs -put -f /home/opc/sales.csv /user/opc/sales/ &&
    spark-submit --master yarn --deploy-mode cluster \
      --num-executors 3 --executor-cores 4 --executor-memory 8g \
      /home/opc/sales_report.py \
      hdfs:///user/opc/sales/sales.csv hdfs:///user/opc/sales_report
  '

  # 3. Read the report back:
  ssh opc@$TARGET_IP 'hdfs dfs -cat /user/opc/sales_report/part-*.csv'

Tip: the job also reads oci:// paths directly — swap the hdfs:/// arguments for
oci://$SCRIPTS_BUCKET@$OS_NAMESPACE/... to use Object Storage instead of HDFS.
EOF
