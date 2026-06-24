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

{{/* "true" when the Altinity clickhouse-backup engine is active. */}}
{{- define "clickhouse.backup.chbEnabled" -}}
{{- and .Values.backup.enabled (eq .Values.backup.engine "clickhouse-backup") -}}
{{- end -}}

{{/* Secret holding clickhouse-backup remote credentials (or an existing one). */}}
{{- define "clickhouse.backup.chbSecretName" -}}
{{- $chb := .Values.backup.clickhouseBackup -}}
{{- $default := printf "%s-backup" (include "clickhouse.fullname" .) -}}
{{- if eq $chb.remoteStorage "gcs" -}}
{{- $chb.gcs.existingSecret | default $default -}}
{{- else -}}
{{- $chb.s3.existingSecret | default $default -}}
{{- end -}}
{{- end -}}

{{/* Environment for the clickhouse-backup sidecar (config is env-driven). */}}
{{- define "clickhouse.backup.chbEnv" -}}
{{- $secret := include "clickhouse.secretName" . -}}
{{- $chbSecret := include "clickhouse.backup.chbSecretName" . -}}
{{- $chb := .Values.backup.clickhouseBackup -}}
- name: LOG_LEVEL
  value: info
- name: API_LISTEN
  value: "0.0.0.0:{{ $chb.apiPort }}"
- name: API_USERNAME
  value: {{ .Values.auth.admin.username | quote }}
- name: API_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: admin-password
- name: CLICKHOUSE_HOST
  value: localhost
- name: CLICKHOUSE_PORT
  value: "9000"
- name: CLICKHOUSE_USERNAME
  value: {{ .Values.auth.admin.username | quote }}
- name: CLICKHOUSE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: admin-password
- name: REMOTE_STORAGE
  value: {{ $chb.remoteStorage | quote }}
- name: BACKUPS_TO_KEEP_REMOTE
  value: {{ $chb.keepRemote | quote }}
- name: COMPRESSION_FORMAT
  value: {{ $chb.compressionFormat | quote }}
{{- if eq $chb.remoteStorage "s3" }}
- name: S3_BUCKET
  value: {{ $chb.s3.bucket | quote }}
- name: S3_PATH
  value: {{ $chb.s3.path | quote }}
- name: S3_REGION
  value: {{ $chb.s3.region | quote }}
{{- if $chb.s3.endpoint }}
- name: S3_ENDPOINT
  value: {{ $chb.s3.endpoint | quote }}
{{- end }}
- name: S3_FORCE_PATH_STYLE
  value: {{ $chb.s3.forcePathStyle | quote }}
{{- if eq $chb.s3.auth "keys" }}
- name: S3_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $chbSecret }}
      key: access-key
- name: S3_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ $chbSecret }}
      key: secret-key
{{- else if $chb.s3.assumeRoleArn }}
- name: S3_ASSUME_ROLE_ARN
  value: {{ $chb.s3.assumeRoleArn | quote }}
{{- end }}
{{- else if eq $chb.remoteStorage "gcs" }}
- name: GCS_BUCKET
  value: {{ $chb.gcs.bucket | quote }}
- name: GCS_PATH
  value: {{ $chb.gcs.path | quote }}
{{- if eq $chb.gcs.auth "key" }}
- name: GCS_CREDENTIALS_JSON
  valueFrom:
    secretKeyRef:
      name: {{ $chbSecret }}
      key: credentials.json
{{- else if $chb.gcs.saEmail }}
- name: GCS_SA_EMAIL
  value: {{ $chb.gcs.saEmail | quote }}
{{- end }}
{{- end }}
{{- end -}}
