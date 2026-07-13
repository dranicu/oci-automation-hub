#!/usr/bin/env bash

# Copyright (c) 2024, 2026, Oracle and/or its affiliates. All rights reserved.
# The Universal Permissive License (UPL), Version 1.0 as shown at https://oss.oracle.com/licenses/upl/
###############################################################################
# Use case 04 — Secure HA production. Run this ON the operator VM.
#
# Verifies the deployment is the secure, highly-available shape this use case is
# about, resolves the cluster nodes, and prints how to reach the Kerberized
# cluster and run a job. (Like use case 02, spark-submit runs on the cluster and
# needs your SSH key — use 'ssh -A' agent forwarding into the operator.)
###############################################################################
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib.sh
. "$HERE/../lib.sh"

require_bds_secure_ha

BDS_ID="$(bds_active_cluster_id)"

if [ -z "$BDS_ID" ]; then
  _yel "BDS is enabled but no ACTIVE cluster found. Current clusters:"
  bds_cluster_states
  _yel "If a cluster is still CREATING, wait for ACTIVE and retry."
  exit 1
fi

oci bds instance get --bds-instance-id "$BDS_ID" \
  --query 'data.nodes[].{type:"node-type",ip:"ip-address",state:"lifecycle-state"}' \
  --output table 2>/dev/null || true

UTIL_IP="$(bds_node_ip "$BDS_ID" UTILITY)"

cat <<EOF

Cluster is up (secure + HA). SSH to a node from the operator ('ssh -A'):

  ssh opc@${UTIL_IP:-<utility-ip>}
EOF

# Quoted heredoc: the Kerberos commands print verbatim (no local expansion).
cat <<'EOF'
  # --- on the node: this is a Kerberos cluster, so get a ticket before any job ---
  # quickest for a demo — become the hdfs superuser via its keytab:
  KT=$(sudo bash -c 'ls /etc/security/keytabs/*hdfs*.keytab 2>/dev/null' | head -1)
  PRINC=$(sudo klist -kt "$KT" | awk 'NR>3{print $4; exit}')
  sudo -u hdfs kinit -kt "$KT" "$PRINC" && sudo -u hdfs klist   # confirm the ticket

  # then submit as hdfs (bring your own job; example):
  sudo -u hdfs spark-submit --master yarn --deploy-mode cluster \
    --num-executors 8 --executor-cores 4 --executor-memory 16g \
    your_job.py args...
EOF

cat <<EOF

To run as your OWN user, create a principal on the master node
('sudo kadmin.local' -> 'addprinc opc', needs the cluster/KDC admin creds), then
'kinit opc'. See the OCI Big Data Service docs on secure clusters.

The bootstrap.sh in this folder is a DEPLOY-TIME artifact — you upload it to
Object Storage and point 'Bootstrap script URL' at it BEFORE the apply, and BDS
runs it on every node at cluster creation (you never run it yourself). Verify it
landed:

  ssh opc@${UTIL_IP:-<utility-ip>} 'grep -A3 "stack bootstrap" /etc/spark3/conf/spark-defaults.conf'
EOF
