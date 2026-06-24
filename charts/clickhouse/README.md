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
- Optional scheduled **backup CronJobs** (to S3 or a local volume).

## Architecture

| Component | When | Description |
|-----------|------|-------------|
| Server `StatefulSet` | always | ClickHouse server pods. 1 pod standalone; `shards × replicasPerShard` pods in HA. |
| Keeper `StatefulSet` | `ha.enabled=true` | Raft quorum for replication coordination (replaces ZooKeeper). |
| Headless + ClusterIP `Service` | always | Stable per-pod DNS and a load-balanced client endpoint. |
| Auth `Secret` | always | Auto-generated, upgrade-stable passwords. |
| Config / users / init `ConfigMap`s | always | Cluster topology, user XML, and bootstrap SQL. |
| Backup `CronJob` + `Secret` | `backup.enabled=true` | Scheduled `BACKUP DATABASE …`. |
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

```yaml
backup:
  enabled: true
  schedule: "0 2 * * *"        # nightly, UTC
  databases: []                # empty = all of .Values.databases
  destination:
    type: s3                   # s3 | path
    s3:
      endpoint: https://s3.amazonaws.com/my-bucket/clickhouse
      accessKeyId: AKIA...
      secretAccessKey: ...
      # or: existingSecret: my-s3-creds  (keys: access-key-id, secret-access-key)
```

Each run issues `BACKUP DATABASE <db> TO S3('<endpoint>/<db>/<timestamp>', …)`
against the cluster. For `type: path`, backups are written to a PVC mounted on
the server pods (`backup.persistence.enabled=true`) and a `<backups>` allowed
path is configured automatically.

Trigger an immediate backup:

```bash
kubectl create job -n data --from=cronjob/ch-clickhouse-backup manual-001
```

Restore example:

```sql
RESTORE DATABASE analytics FROM S3('<endpoint>/analytics/<timestamp>', '<key>', '<secret>');
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
| `backup.enabled` | `false` | Schedule backup CronJobs. |
| `metrics.enabled` | `false` | Expose the Prometheus endpoint. |

See [`values.yaml`](values.yaml) for the full list.

## Notes & requirements

- The container runs as the non-root `clickhouse` user (uid/gid `101`);
  `podSecurityContext.fsGroup` ensures the data volume is writable.
- Pin `image.tag` (or `Chart.appVersion`) to a ClickHouse release you have
  validated before production use.
- Run the bundled smoke test after install: `helm test ch -n data`.
