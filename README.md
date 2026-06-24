# charts.ipx.dev

A [Helm](https://helm.sh) chart repository, served via GitHub Pages.

## Usage

```bash
helm repo add ipx https://charts.ipx.dev
helm repo update
helm search repo ipx
```

Install a chart:

```bash
helm install ch ipx/clickhouse --namespace data --create-namespace
```

## Available charts

| Chart | Description |
|-------|-------------|
| [`clickhouse`](charts/clickhouse) | Optionally highly-available [ClickHouse](https://clickhouse.com) cluster — admin account, databases, application users, and scheduled backups. |

See each chart's own README for values and examples.

## How releases work

Charts live under [`charts/`](charts). On every push to `main`,
[`helm/chart-releaser-action`](https://github.com/helm/chart-releaser-action)
packages any chart whose `version` changed, publishes the `.tgz` as a GitHub
Release, and updates `index.yaml` on the `gh-pages` branch (the repo Pages
source). Bump the chart's `version` in its `Chart.yaml` to cut a release.

Pull requests are linted with `helm lint --strict` and a `helm template`
render check (see [`.github/workflows`](.github/workflows)).

## Local development

```bash
helm lint charts/clickhouse --strict
helm template charts/clickhouse
helm install ch charts/clickhouse --dry-run --debug
```
