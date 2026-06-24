{{/* vim: set filetype=mustache: */}}

{{- define "clickhouse.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clickhouse.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "clickhouse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clickhouse.keeper.fullname" -}}
{{- printf "%s-keeper" (include "clickhouse.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clickhouse.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.image.repository $tag -}}
{{- end -}}

{{- define "clickhouse.labels" -}}
helm.sh/chart: {{ include "clickhouse.chart" . }}
{{ include "clickhouse.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: clickhouse
{{- end -}}

{{- define "clickhouse.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clickhouse.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "clickhouse.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "clickhouse.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "clickhouse.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- printf "%s-auth" (include "clickhouse.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/* Number of replicas per shard, forced to 1 when HA is disabled. */}}
{{- define "clickhouse.replicasPerShard" -}}
{{- if .Values.ha.enabled -}}{{ max 1 (int .Values.clickhouse.replicasPerShard) }}{{- else -}}1{{- end -}}
{{- end -}}

{{/* Number of shards, forced to 1 when HA is disabled. */}}
{{- define "clickhouse.shards" -}}
{{- if .Values.ha.enabled -}}{{ max 1 (int .Values.clickhouse.shards) }}{{- else -}}1{{- end -}}
{{- end -}}

{{/* Total number of server pods. */}}
{{- define "clickhouse.totalReplicas" -}}
{{- mul (int (include "clickhouse.shards" .)) (int (include "clickhouse.replicasPerShard" .)) -}}
{{- end -}}

{{/* Headless service DNS suffix for stable per-pod addressing. */}}
{{- define "clickhouse.headlessDomain" -}}
{{- printf "%s-headless.%s.svc.%s" (include "clickhouse.fullname" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}

{{- define "clickhouse.keeper.headlessDomain" -}}
{{- printf "%s-headless.%s.svc.%s" (include "clickhouse.keeper.fullname" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}

{{/* Convert a username/db into an env-var-safe suffix. */}}
{{- define "clickhouse.envKey" -}}
{{- . | upper | replace "-" "_" | replace "." "_" -}}
{{- end -}}
