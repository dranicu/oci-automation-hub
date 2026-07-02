# Use case 02 — Analytics on a managed Hadoop cluster

**Goal:** run a Spark job with `spark-submit` against YARN on a real Hadoop
cluster — reading from and writing to HDFS. The classic "I want a cluster I can
log into" experience, fully managed by OCI Big Data Service (BDS).

Use this when you need long-running services (Hive metastore, HBase, Trino), an
interactive cluster, or workloads that don't fit the serverless Data Flow model.

## Requires in the Resource Manager form

| Field | Value |
|-------|-------|
| Deploy Big Data Service (Hadoop) | **on** |
| Cluster profile | HADOOP_EXTENDED (default) |
| Deploy operator VM behind OCI Bastion | on |
| SSH public key | your key (for the operator **and** BDS nodes) |

> BDS provisioning takes **~30 minutes** and the worker nodes bill continuously.
> Destroy the stack when you're done.

## Run it (from the operator VM)

`spark-submit` has to run **on a BDS node**, and SSH from the operator to BDS
uses **your** private key (we never put private keys on the operator). So you
must reach the operator with **agent forwarding**. In short:

```bash
# on your LAPTOP, before connecting:
ssh-add ~/.ssh/id_rsa        # load the key into your agent (not just -i !)
ssh-add -l                   # confirm it's listed

# connect to the operator WITH -A (see ../README.md §2 for the full command)
ssh -A -o ProxyCommand="..." -i ~/.ssh/id_rsa opc@<OPERATOR_PRIVATE_IP>

# on the OPERATOR, confirm the key came across:
ssh-add -l                   # should list the same key
```

The full step-by-step (and why `-i` alone isn't enough) is in
[../README.md](../README.md) §2a–2c. Then:

```bash
cd use-cases/02-hadoop-cluster-analytics
./submit.sh
```

`submit.sh` self-checks that BDS is deployed, resolves the cluster's utility/
master node private IPs for you, and prints the exact `scp` / `ssh` /
`spark-submit` commands to copy the job over and run it on the cluster. It runs:

```bash
spark-submit --master yarn --deploy-mode cluster \
  --num-executors 3 --executor-cores 4 --executor-memory 8g \
  /home/opc/sales_report.py \
  hdfs:///user/opc/sales/sales.csv hdfs:///user/opc/sales_report
```

Read the result back from HDFS:

```bash
ssh opc@<node-ip> 'hdfs dfs -cat /user/opc/sales_report/part-*.csv'
```

### Secure (Kerberos) clusters

The commands above are for a **non-secure** cluster (this use case's intended
shape). If you deployed with **Secure cluster = on** (Kerberos + Ranger — the
[use case 04](../04-secure-ha-production/) shape), HDFS/YARN reject any command
without a Kerberos ticket:

```
org.apache.hadoop.security.AccessControlException:
  Client cannot authenticate via:[TOKEN, KERBEROS]
```

`submit.sh` detects this (`BDS_SECURE=true` in `deployment.env`) and instead
prints a **Kerberos-aware** version of the steps: get a ticket first (`kinit` —
quickest as the `hdfs` superuser using its keytab, or create a principal for your
own user with `kadmin` on the master node), then run the job. Follow what the
script prints. To use the plain flow shown above, redeploy with Secure = off.

Web UIs (Ambari, Hue, Spark History, YARN RM on port 8088) are served from the
utility node — tunnel to them over SSH from the operator.

## What the job demonstrates

`sales_report.py`:

- Reads a sales CSV from **HDFS** (the on-cluster story).
- Computes revenue by region and product category, plus each category's share of
  total revenue using a window function.
- Writes a single coalesced CSV report back to HDFS.

It runs on YARN in cluster mode, so the driver and executors schedule across your
worker nodes — scale `bds_worker_count` (or add compute-only workers, see
[use case 04](../04-secure-ha-production/)) and the same job spreads wider.

### Reading Object Storage from the cluster

BDS reads `oci://` paths directly (HDFS connector + resource principal), so you
can keep data in Object Storage and treat the cluster as pure compute — swap the
`hdfs:///...` arguments for `oci://bucket@namespace/...`. `submit.sh` prints the
scripts-bucket URI to make that easy.

## If it can't run

If BDS isn't deployed, `submit.sh` stops with:

```
This use case can't run on the current deployment.
  Big Data Service is not deployed. Set 'Deploy Big Data Service (Hadoop)' = on.
```
