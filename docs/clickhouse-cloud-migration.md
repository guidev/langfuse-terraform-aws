# Migrating Langfuse from bundled ClickHouse to ClickHouse Cloud (production runbook)

Status: PLAN — nothing in here has been applied. Tailored to the `solomei` / `solomei-infra`
deployment (`tracing.solomei.ai`).

Chosen parameters for this migration:

- **History:** migrate **all** historical data (zero loss).
- **Cutover style:** **freeze workers only** — scale `langfuse-worker` to 0 during the copy;
  `langfuse-web` stays up, new events buffer in S3 + Redis and are drained after cutover.
- **ClickHouse Cloud:** **not yet provisioned** — provisioning is Phase 0.
- **Connectivity:** **AWS PrivateLink**, same region (eu-west-1) — private, $0 ClickHouse-side
  transfer, no NAT-EIP allow-list.

---

## 0. Why the Terraform change alone is NOT the migration

Flipping `clickhouse_deploy = false` only **reconfigures Langfuse to talk to a different
ClickHouse**. It does **not** move any data, and on its own it **destroys** the bundled
ClickHouse + the EFS filesystem that holds all historical traces. The data migration is a
separate, manual ClickHouse-to-ClickHouse copy that must happen **before** the flip, while the
old cluster is still running.

Three things found during review that make a naive flip dangerous:

| # | Risk | Mitigation in this runbook |
|---|------|----------------------------|
| 1 | **Plaintext HTTP on a TLS port.** The Helm chart derives the `CLICKHOUSE_URL` scheme *only* from an `https://` prefix on the host; `clickhouse_ssl`/`migration.ssl` only affects the native migration URL. A bare host + `httpPort 8443` → `http://host:8443` → all queries fail. | Module now auto-prefixes `https://` when `clickhouse_ssl = true` (`langfuse.tf` `clickhouse_host_effective`). Pass a bare host and keep `clickhouse_ssl = true`. |
| 2 | **EFS (the only copy of source data) is destroyed on flip**, with no snapshot and no rollback. | New `retain_clickhouse_efs = true` flag keeps EFS through cutover for rollback; also take an AWS Backup recovery point. Decommission EFS only after soak. |
| 3 | **The branch consolidates NAT gateways 2 → 1.** With PrivateLink the ClickHouse path no longer depends on the NAT egress IP, but this still changes egress for *other* traffic (image pulls, OIDC, external APIs) and reduces AZ resilience. | Handle as a **separate, deliberate apply** — not on the ClickHouse path. Review the plan; accept 2→1 or revert `vpc.tf` to keep 2. |

> ⚠️ **NAT heads-up:** `solomei-infra` references this module by **local path**, so the NAT-logic
> fix is *already* in the code your next `terraform apply` will use. The very next apply (even the
> pending `1.5.30 → 1.5.32` Helm bump) will show `aws_nat_gateway` / `aws_eip`
> destroy+create in the plan. Production currently has **2** NAT gateways
> (`52.50.243.193`, `18.202.106.81`); the fix reduces this to **1**. With PrivateLink this is **not**
> on the ClickHouse path, but still review the plan and apply it deliberately, on its own.

---

## Pre-flight: pin the Langfuse version

Do the migration on a **single, fixed** Langfuse app version so the schema the migrator creates on
Cloud matches the data you copy and the version prod runs after cutover.

1. Finish the in-flight `langfuse_helm_chart_version = "1.5.32"` bump (Langfuse app **v3.175.0**)
   on the **current bundled** setup and let it stabilize. Do **not** combine the app upgrade with
   the CH cutover.
2. Record the exact running worker image — this is the image the schema migrator must use:
   ```bash
   kubectl -n langfuse get deploy langfuse-worker \
     -o jsonpath='{.spec.template.spec.containers[0].image}'   # e.g. langfuse/langfuse-worker:3.175.0
   ```

---

## Phase 0 — Provision & prepare (no production impact)

### 0.1 Provision ClickHouse Cloud
- Create a service in the **same AWS region as the EKS cluster** (`eu-west-1` / Ireland — that's
  where the NAT EIPs live) to minimise latency and cross-region egress.
- Tier: a **Production/Scale** service (not the dev tier) for HA + SharedMergeTree.
- ClickHouse Cloud uses `SharedMergeTree` and does **not** want `ON CLUSTER` →
  `clickhouse_cluster_enabled = false` (module default) is correct.
- Capture: HTTPS port `8443`, native TLS port `9440`, and the `default` user password (or a
  dedicated user, see 0.2). The **host** you wire into Terraform is the PrivateLink
  `privateDnsHostname` from 0.3 — not the public host.

### 0.2 Create the Langfuse ClickHouse user/grants
Langfuse needs DDL + DML. Either use `default`, or a dedicated user with at minimum:
```sql
GRANT SELECT, INSERT, ALTER UPDATE, ALTER DELETE, ALTER ADD COLUMN, ALTER DROP COLUMN,
      ALTER MODIFY COLUMN, CREATE TABLE, CREATE VIEW, DROP TABLE, DROP VIEW,
      ALTER ADD INDEX, ALTER DROP INDEX, OPTIMIZE
ON default.* TO langfuse;
```
Use the same DB name you'll set in `clickhouse_database` (default `default`).

### 0.3 Connectivity — AWS PrivateLink (chosen)
Connect over **AWS PrivateLink**, same region (eu-west-1): private, no public exposure, no NAT-EIP
allow-list to maintain, and ClickHouse charges **$0** for same-region transfer (you pay only AWS's
~$0.011/GB + ~$0.011/hr/AZ for the endpoint). Set it up here so both the bulk copy (Phase 2) and
steady state ride it. PrivateLink requires the Cloud **Scale/Enterprise** tier (already assumed).

1. **Get the endpoint config from Cloud** (Console → service → Settings → "Set up private endpoint",
   or the `privateEndpointConfig` API). Two values:
   - `endpointServiceId` — e.g. `com.amazonaws.vpce.eu-west-1.vpce-svc-xxxx`
   - `privateDnsHostname` — e.g. `xxxx.eu-west-1.vpce.aws.clickhouse.cloud` ← **this is the host you
     connect to.** The public host routes over the internet; `privateDnsHostname` routes over PrivateLink.
2. **Create the interface VPC endpoint** in the cluster's VPC + private subnets:
   ```hcl
   resource "aws_security_group" "clickhouse_pl" {
     name   = "langfuse-clickhouse-privatelink"
     vpc_id = module.langfuse.vpc_id

     ingress {
       description = "ClickHouse HTTPS"
       from_port   = 8443
       to_port     = 8443
       protocol    = "tcp"
       cidr_blocks = ["10.0.0.0/16"] # VPC CIDR
     }
     ingress {
       description = "ClickHouse native (TLS)"
       from_port   = 9440
       to_port     = 9440
       protocol    = "tcp"
       cidr_blocks = ["10.0.0.0/16"]
     }
     egress {
       from_port   = 0
       to_port     = 0
       protocol    = "-1"
       cidr_blocks = ["0.0.0.0/0"]
     }
   }

   resource "aws_vpc_endpoint" "clickhouse" {
     vpc_id              = module.langfuse.vpc_id
     service_name        = "<endpointServiceId>"
     vpc_endpoint_type   = "Interface"
     subnet_ids          = module.langfuse.private_subnet_ids
     security_group_ids  = [aws_security_group.clickhouse_pl.id]
     private_dns_enabled  = false # third-party service — we manage DNS in step 4
   }
   ```
   (`module.langfuse.vpc_id` is a new output added for this.)
3. **Authorize the endpoint on Cloud**: add `aws_vpc_endpoint.clickhouse.id` (`vpce-xxxx`) to the
   service's private-endpoint allow-list (Console "Set up private endpoint" → enter the Endpoint ID,
   or API `PATCH …/services/{id}` with `privateEndpointIds.add`). Once verified, optionally lock the
   service to **private-only** via its IP Access List.
4. **Resolve `privateDnsHostname` inside the VPC** to the endpoint (needed because
   `private_dns_enabled = false`): a Route 53 **private hosted zone** + CNAME → the endpoint DNS:
   ```hcl
   resource "aws_route53_zone" "ch" {
     name = "vpce.aws.clickhouse.cloud"
     vpc { vpc_id = module.langfuse.vpc_id }
   }
   resource "aws_route53_record" "ch" {
     zone_id = aws_route53_zone.ch.zone_id
     name    = "<privateDnsHostname>"
     type    = "CNAME"
     ttl     = 60
     records = [aws_vpc_endpoint.clickhouse.dns_entry[0].dns_name]
   }
   ```
5. **Verify resolution + reachability from inside the cluster** before Phase 1/2:
   ```bash
   kubectl -n langfuse exec -it langfuse-clickhouse-shard0-0 -- bash -lc \
     "getent hosts <privateDnsHostname>; \
      clickhouse-client --host <privateDnsHostname> --port 9440 --secure \
        --user <user> --password <password> --query 'SELECT 1'"
   ```

IaC option: provision the Cloud service + endpoint registration with the **`ClickHouse/clickhouse`
Terraform provider** (`clickhouse_service` + its private-endpoint attributes) in `solomei-infra`,
and feed `privateDnsHostname` straight into the module's `clickhouse_host`.

> Phase 2's copy and steady state both use `privateDnsHostname`, so **all** traffic — including the
> one-time bulk push — rides PrivateLink. The NAT egress IP is not on the ClickHouse path, so the
> NAT 2→1 change is decoupled from this migration.

### 0.4 Size the data (informs the freeze window)
```bash
CH_PASS=$(kubectl -n langfuse get secret langfuse -o jsonpath='{.data.clickhouse-password}' | base64 -d)
kubectl -n langfuse exec -it langfuse-clickhouse-shard0-0 -- clickhouse-client --password "$CH_PASS" --query "
  SELECT table, formatReadableSize(sum(bytes_on_disk)) AS size, sum(rows) AS rows
  FROM system.parts WHERE database='default' AND active GROUP BY table ORDER BY sum(bytes_on_disk) DESC"
```
This tells you how long the worker-freeze copy window will be.

---

## Phase 1 — Create the Langfuse schema on Cloud (source untouched)

The data copy needs the destination tables (and materialized views) to exist **first**, created by
Langfuse's own migrations so the engines and `schema_migrations` version are correct for Cloud.
Do this **out-of-band**, while the bundled cluster keeps serving prod (`clickhouse_deploy` stays
`true`).

**Method: a one-off migration pod using the exact prod worker image, isolated from the queue.**

1. Stand up a throwaway Redis so the migrator has an empty queue and won't process/duplicate jobs:
   ```bash
   kubectl -n langfuse run tmp-redis --image=redis:7 --restart=Never
   ```
2. Clone the prod worker, point ClickHouse at Cloud and Redis at the throwaway, scale to 1, strip
   probes. The worker runs Postgres (idempotent, same version → no-op) and **ClickHouse** migrations
   on boot, creating the full schema + MVs on Cloud, then idles on the empty queue.
   - Set: `CLICKHOUSE_URL=https://<cloud-host>:8443`,
     `CLICKHOUSE_MIGRATION_URL=clickhouse://<cloud-host>:9440`,
     `CLICKHOUSE_MIGRATION_SSL=true`, `CLICKHOUSE_CLUSTER_ENABLED=false`,
     `CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_DB=default`,
     `REDIS_CONNECTION_STRING=redis://tmp-redis:6379/0`,
     `LANGFUSE_AUTO_CLICKHOUSE_MIGRATION_DISABLED=false`.
3. Verify on Cloud, then tear the migrator + tmp-redis down:
   ```sql
   -- on Cloud
   SELECT count() FROM system.tables WHERE database='default';
   SELECT max(version) FROM default.schema_migrations;   -- compare to source (see below)
   ```
   ```bash
   # on source — must match the Cloud migration version
   kubectl -n langfuse exec -it langfuse-clickhouse-shard0-0 -- clickhouse-client --password "$CH_PASS" \
     --query "SELECT max(version) FROM default.schema_migrations"
   ```
   Source and Cloud `schema_migrations` versions **must match**. Then:
   ```bash
   kubectl -n langfuse delete pod tmp-redis
   kubectl -n langfuse delete deploy langfuse-ch-migrator   # whatever you named the clone
   ```

> Alternative (no migrator pod): dump DDL from source with `SHOW CREATE TABLE` for every table/MV,
> strip `ON CLUSTER` and convert `Replicated*MergeTree('/path','{replica}', …)` →
> `*MergeTree(…)` (drop the two replication args, keep version/sign columns), replay on Cloud, then
> copy the `schema_migrations` rows. Deterministic but error-prone by hand — prefer the migrator.

---

## Phase 2 — Freeze writes, copy all data, verify

### 2.1 Freeze (web stays up; no data loss)
```bash
kubectl -n langfuse scale deploy langfuse-worker --replicas=0
```
`langfuse-web` keeps accepting traces → events land in S3 (`events/`) and the Redis queue and wait.
The bundled ClickHouse is now write-quiescent → a consistent snapshot to copy.

### 2.2 Classify tables (avoid materialized-view double-counting)
On Cloud the MVs already exist (Phase 1). When you `INSERT` into a **base** table, any MV reading
from it fires and fills its **target** table automatically. So:

- **Copy** every base table — i.e. tables that are **not** the `TO` target of a materialized view
  (e.g. `traces`, `observations`, `scores`, `dataset_run_items`, `event_log`,
  `blob_storage_file_log`).
- **Skip** MV target tables — they're repopulated by the MV during the base-table inserts.
- **Skip** `schema_migrations` — managed by Langfuse (already set in Phase 1).
- Materialized views themselves hold no data.

Enumerate and classify from the source (don't hardcode — verify against your version):
```sql
SELECT name, engine FROM system.tables WHERE database='default' ORDER BY name;
-- MVs: engine='MaterializedView'. For each, read its TO target:
SELECT name, create_table_query FROM system.tables
WHERE database='default' AND engine='MaterializedView';
```

### 2.3 Copy (push from inside the cluster)
For each base table, run from a source CH pod (it has `clickhouse-client` and egress to Cloud):
```bash
kubectl -n langfuse exec -it langfuse-clickhouse-shard0-0 -- clickhouse-client --password "$CH_PASS" --query "
  INSERT INTO FUNCTION remoteSecure('<privateDnsHostname>:9440', 'default.traces', '<user>', '<password>')
  SELECT * FROM default.traces SETTINGS max_execution_time=0"
```
- `<privateDnsHostname>` resolves to the PrivateLink endpoint inside the VPC (Phase 0.3), so the copy
  rides PrivateLink — no public egress, no IP allow-list.
- `remoteSecure` (not `remote`) → TLS, matching Cloud's `9440`.
- For very large tables, slice by partition to bound memory / allow resume, e.g. append
  `WHERE toYYYYMM(event_ts) = 202604` and loop over months.
- Repeat for `observations`, `scores`, `dataset_run_items`, `event_log`, `blob_storage_file_log`,
  and any other base tables found in 2.2.

### 2.4 Verify (per table, source vs Cloud)
```sql
-- raw counts
SELECT count() FROM default.traces;                     -- run on source AND Cloud
-- ReplacingMergeTree tables dedupe on merge; also compare deduped:
SELECT count() FROM default.traces FINAL;               -- or: SELECT uniqExact(id) FROM default.traces
-- sanity on time range:
SELECT min(event_ts), max(event_ts) FROM default.traces;
```
Then spot-check that **MV-target tables on Cloud** have plausible counts (they were filled by the
MVs during 2.3). Investigate any material discrepancy before proceeding. Do **not** cut over until
counts reconcile.

---

## Phase 3 — Cutover

### 3.1 Rollback artifact
Even with `retain_clickhouse_efs = true`, take an on-demand backup of the EFS filesystem:
```bash
# find the FS id (tag Name = "langfuse"), then start an AWS Backup on-demand job, or:
aws efs describe-file-systems --query "FileSystems[?Name=='langfuse'].FileSystemId"
```
Keep the recovery point ≥ the soak period.

### 3.2 Apply the Terraform flip
In `solomei-infra/langfuse.tf`, add to the `module "langfuse"` block:
```hcl
  # --- external ClickHouse (ClickHouse Cloud) ---
  clickhouse_deploy          = false
  clickhouse_host            = "<privateDnsHostname>"   # PrivateLink host (xxxx.eu-west-1.vpce.aws.clickhouse.cloud); module adds https:// (ssl=true)
  clickhouse_http_port       = 8443
  clickhouse_native_port     = 9440
  clickhouse_ssl             = true
  clickhouse_cluster_enabled = false
  clickhouse_database        = "default"
  clickhouse_user            = "default"
  clickhouse_password        = var.clickhouse_cloud_password   # sensitive var, NOT a literal
  retain_clickhouse_efs      = true             # keep EFS for rollback; set false later
```
Add the sensitive variable and pass it via `TF_VAR_clickhouse_cloud_password` (or Secrets Manager):
```hcl
variable "clickhouse_cloud_password" { type = string, sensitive = true }
```
Then:
```bash
terraform plan    # EXPECT: web/worker reconfigured to Cloud; bundled CH StatefulSet + zookeeper +
                  # access points + PVs destroyed; EFS filesystem RETAINED (count stays 1).
                  # Confirm aws_efs_file_system.langfuse is NOT in the destroy list.
terraform apply
```

### 3.3 Drain the backlog
```bash
kubectl -n langfuse scale deploy langfuse-worker --replicas=1   # or your normal count
```
Workers reconnect to Cloud and drain the S3/Redis events buffered during the freeze → the gap is
backfilled, zero loss.

### 3.4 Smoke test
- `langfuse-web` and `langfuse-worker` pods healthy; logs show a successful Cloud connection and
  **no** migration errors (auto-migrate should be a no-op — schema already current).
- UI shows **historical** traces (from the copy) **and** new traces appearing.
- Dashboards / metrics (MV-backed) render.
- `SELECT count() FROM default.traces` on Cloud keeps climbing as new data lands.

---

## Phase 4 — Soak & decommission

1. Run on Cloud for a soak period (suggest **1–2 weeks**) with EFS + AWS Backup retained.
2. Decommission the old data:
   ```hcl
   retain_clickhouse_efs = false   # next apply destroys the retained EFS filesystem
   ```
   `terraform apply`, then delete the AWS Backup recovery point once comfortable.
3. Rotate the old in-cluster ClickHouse password (now unused) if it was ever exposed during the copy.

---

## Rollback (break-glass, any time before Phase 4)

EFS is retained, so reverting is fast:
```hcl
clickhouse_deploy     = true
retain_clickhouse_efs = true   # (no longer strictly needed once deploy=true)
# remove/neutralise the external clickhouse_* settings
```
`terraform apply` → bundled ClickHouse restarts, remounts the retained EFS data, workers reconnect
and drain the backlog into the old cluster. Data written **only** to Cloud after the flip is lost
on rollback — so decide quickly during the smoke test, before significant new volume accumulates.
If EFS was already destroyed, restore it from the AWS Backup recovery point first.

---

## Module changes made to support this (already applied to the `solomei` branch, uncommitted)

- `langfuse.tf`: `clickhouse_host_effective` local — auto-prefixes `https://` when
  `clickhouse_ssl = true`, fixing the plaintext-on-TLS-port bug (Risk #1).
- `variables.tf`: `retain_clickhouse_efs` variable; clarified `clickhouse_host` description.
- `efs.tf`: EFS filesystem retained when `clickhouse_deploy = false && retain_clickhouse_efs = true`
  (Risk #2). Mount targets / SG / access points / PVs still gated on `clickhouse_deploy` (only
  needed while bundled CH runs).
- `outputs.tf`: new `vpc_id` output — lets `solomei-infra` attach the ClickHouse Cloud PrivateLink
  interface endpoint to the cluster VPC.

## References
- Langfuse — [ClickHouse (self-hosted) env vars](https://langfuse.com/self-hosting/deployment/infrastructure/clickhouse)
- Langfuse — [Self-hosted ClickHouse migration discussion #12668](https://github.com/orgs/langfuse/discussions/12668)
- ClickHouse — [Migrating self-managed → Cloud with remoteSecure](https://clickhouse.com/docs/cloud/migration/clickhouse-to-cloud)
- ClickHouse — [AWS PrivateLink setup](https://clickhouse.com/docs/manage/security/aws-privatelink) · [network data transfer pricing](https://clickhouse.com/docs/cloud/manage/network-data-transfer)
