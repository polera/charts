# ClickHouse Helm Chart

Bootstrap an **optionally highly-available** [ClickHouse](https://clickhouse.com)
cluster on Kubernetes using the official
[`clickhouse`](https://hub.docker.com/_/clickhouse) image.

The chart provisions, in one step:

- An **admin (superuser)** account with SQL-driven access management.
- Any number of **non-default databases**.
- Application **user accounts** with per-database grants.
- Optional **High Availability** via a ClickHouse Keeper ensemble and replicated
  `Replicated*MergeTree` tables.
- Optional scheduled **backups** to S3, GCS, or a local volume — via ClickHouse's
  native `BACKUP` or an Altinity `clickhouse-backup` sidecar with keyless cloud auth.

## Architecture

| Component | When | Description |
|-----------|------|-------------|
| Server `StatefulSet` | always | ClickHouse server pods. 1 pod standalone; `shards × replicasPerShard` pods in HA. |
| Keeper `StatefulSet` | `ha.enabled=true` | Raft quorum for replication coordination (replaces ZooKeeper). |
| Headless + ClusterIP `Service` | always | Stable per-pod DNS and a load-balanced client endpoint. |
| Auth `Secret` | always | Auto-generated, upgrade-stable passwords. |
| Config / users / init `ConfigMap`s | always | Cluster topology, user XML, and bootstrap SQL. |
| Backup `CronJob` (+ `Secret`) | `backup.enabled=true` | Scheduled backups. `engine=native` runs `BACKUP DATABASE …`; `engine=clickhouse-backup` adds a sidecar to the server pods and triggers it over its REST API. |
| `PodDisruptionBudget` | HA | Keeps a minimum of replicas available during disruptions. |
| `ServiceMonitor` | `metrics.serviceMonitor.enabled` | Prometheus scrape config. |

Per-pod ClickHouse `macros` (`shard`/`replica`) and per-keeper raft `server_id`
are derived from the pod ordinal by an init container, so a single StatefulSet
yields a correctly-configured cluster.

## Quick start

```bash
# Standalone single node
helm install ch ./clickhouse --namespace data --create-namespace

# Highly available: 3 keepers, 1 shard x 2 replicas
helm install ch ./clickhouse --namespace data --create-namespace \
  --set ha.enabled=true
```

Fetch the generated admin password:

```bash
kubectl get secret -n data ch-clickhouse-auth \
  -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

## How credentials work

Passwords live only in the chart-managed `Secret` (or one you supply via
`auth.existingSecret`). They are generated with `randAlphaNum` on first install
and **preserved across upgrades** via a `lookup` of the existing secret, so
`helm upgrade` never rotates them unless you set an explicit value.

- The built-in **`default`** user is configured by the image entrypoint
  (`CLICKHOUSE_PASSWORD`) and is used for inter-node replication and
  distributed queries.
- The **admin** user is defined in `users.d` with `access_management` enabled
  and is what the bootstrap SQL uses to create databases, users and grants.
- Config XML never embeds plaintext — passwords are injected at runtime via
  ClickHouse's `from_env` attribute backed by the Secret.

## Databases & users

```yaml
databases:
  - analytics
  - events

users:
  - name: app
    databases: [analytics, events]   # GRANT ALL ON <db>.*  (use ["*"] for all)
    allowedNetworks: ["10.0.0.0/8"]  # ["::/0"] -> HOST ANY
    profile: default
    quota: default
```

Databases are created idempotently on every node's first boot. In HA mode RBAC
is stored in Keeper (`replicated` access storage) so users/grants propagate to
all replicas automatically.

To create a replicated table in HA mode, use the `{cluster}`, `{shard}` and
`{replica}` macros, e.g.:

```sql
CREATE TABLE analytics.hits ON CLUSTER '{cluster}' (...)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/hits', '{replica}')
ORDER BY ...;
```

## Backups

Two engines are available via `backup.engine`:

| Engine | Object-store auth | Notes |
|--------|-------------------|-------|
| `native` (default) | HMAC keys only | ClickHouse's built-in `BACKUP … TO`. Simple, streams directly. |
| `clickhouse-backup` | HMAC keys **or keyless** (EKS IRSA / GKE Workload Identity) | [Altinity clickhouse-backup](https://github.com/Altinity/clickhouse-backup) sidecar + retention/incremental. |

Use `clickhouse-backup` if you want keyless cloud auth — in particular, **GCS
Workload Identity is only possible with this engine** (the native engine reaches
GCS through its S3-interop endpoint, which accepts HMAC keys only).

### Engine: `native`

```yaml
backup:
  enabled: true
  engine: native
  schedule: "0 2 * * *"        # nightly, UTC
  databases: []                # empty = all of .Values.databases
  destination:
    type: s3                   # s3 | gcs | path
    s3:
      endpoint: https://s3.amazonaws.com/my-bucket/clickhouse
      accessKeyId: AKIA...
      secretAccessKey: ...
      # or: existingSecret: my-s3-creds  (keys: access-key-id, secret-access-key)
```

Google Cloud Storage uses its S3-compatible interoperability API with HMAC
credentials (create them under *Cloud Storage > Settings > Interoperability*):

```yaml
  destination:
    type: gcs
    gcs:
      endpoint: https://storage.googleapis.com/my-bucket/clickhouse
      accessKeyId: GOOG1E...
      secretAccessKey: ...
      # or: existingSecret: my-gcs-creds  (keys: access-key-id, secret-access-key)
```

Each run issues `BACKUP DATABASE <db> TO S3('<endpoint>/<db>/<timestamp>', …)`
against the cluster (GCS reuses the same S3 backup function). For `type: path`,
backups are written to a PVC mounted on the server pods
(`backup.persistence.enabled=true`) and a `<backups>` allowed path is configured
automatically.

Restore example:

```sql
RESTORE DATABASE analytics FROM S3('<endpoint>/analytics/<timestamp>', '<key>', '<secret>');
```

### Engine: `clickhouse-backup`

A `clickhouse-backup` sidecar runs in every server pod (it needs file access to
`/var/lib/clickhouse`) and exposes a REST API on `apiPort` (7171). A CronJob on
`backup.schedule` calls `create_remote` against each shard's lead replica (and
optionally schema-only on the other replicas). Backups land in object storage as
`<namePrefix>-shard<N>-<timestamp>`.

**S3 with keyless auth (EKS IRSA):**

```yaml
backup:
  enabled: true
  engine: clickhouse-backup
  schedule: "0 2 * * *"
  clickhouseBackup:
    remoteStorage: s3
    s3:
      bucket: my-bucket
      path: clickhouse
      region: us-east-1
      auth: iam              # omit static keys; use the pod's IAM role
      # assumeRoleArn: arn:aws:iam::123456789012:role/clickhouse-backup
serviceAccount:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/clickhouse-backup
```

**GCS with keyless auth (GKE Workload Identity):**

```yaml
backup:
  enabled: true
  engine: clickhouse-backup
  clickhouseBackup:
    remoteStorage: gcs
    gcs:
      bucket: my-bucket
      path: clickhouse
      auth: workloadIdentity
      saEmail: clickhouse-backup@my-project.iam.gserviceaccount.com
serviceAccount:
  annotations:
    iam.gke.io/gcp-service-account: clickhouse-backup@my-project.iam.gserviceaccount.com
```

For static credentials instead, set `s3.auth: keys` with `accessKey`/`secretKey`
(or `s3.existingSecret` with keys `access-key`/`secret-key`), or `gcs.auth: key`
with `credentialsJson` (or `gcs.existingSecret` with key `credentials.json`).

Restore (run against the target pod's sidecar API, e.g. pod `-0`):

```bash
kubectl exec -n data sts/ch-clickhouse-0 -c clickhouse-backup -- \
  clickhouse-backup restore_remote --rm backup-shard0-<timestamp>
```

### Trigger an immediate backup (either engine)

```bash
kubectl create job -n data --from=cronjob/ch-clickhouse-backup manual-001
```

## Key values

| Key | Default | Description |
|-----|---------|-------------|
| `ha.enabled` | `false` | Deploy Keeper + multiple replicas. |
| `clickhouse.shards` | `1` | Shard count (HA only). |
| `clickhouse.replicasPerShard` | `2` | Replicas per shard (HA only). |
| `clickhouse.clusterName` | `default` | Logical cluster / `{cluster}` macro. |
| `image.repository` / `image.tag` | `clickhouse` / appVersion | Official image. |
| `auth.admin.username` | `admin` | Superuser name. |
| `auth.existingSecret` | `""` | Bring your own credential secret. |
| `databases` | `[analytics]` | Databases to create. |
| `users` | `[app]` | Application users + grants. |
| `persistence.size` | `50Gi` | Server data volume size. |
| `keeper.replicas` | `3` | Keeper quorum size (use odd numbers). |
| `backup.enabled` | `false` | Schedule backups. |
| `backup.engine` | `native` | `native` or `clickhouse-backup` (keyless cloud auth). |
| `metrics.enabled` | `false` | Expose the Prometheus endpoint. |

See [`values.yaml`](values.yaml) for the full list.

## Notes & requirements

- The container runs as the non-root `clickhouse` user (uid/gid `101`);
  `podSecurityContext.fsGroup` ensures the data volume is writable.
- Pin `image.tag` (or `Chart.appVersion`) to a ClickHouse release you have
  validated before production use.
- Run the bundled smoke test after install: `helm test ch -n data`.
