{{/* Chart name, overridable. */}}
{{- define "dotnet-service.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name, capped at 63 chars for label validity. */}}
{{- define "dotnet-service.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "dotnet-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Selector labels — immutable. These land in Deployment.spec.selector, which is
an immutable field, so anything that can change across releases (version,
chart) must stay out or upgrades fail with a selector-mismatch error.
*/}}
{{- define "dotnet-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dotnet-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "dotnet-service.labels" -}}
helm.sh/chart: {{ include "dotnet-service.chart" . }}
{{ include "dotnet-service.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: platform
{{- end }}

{{- define "dotnet-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dotnet-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference. Prefers a digest over a tag: Kyverno's require-image-digest
policy rejects mutable tags in production, and a digest is the only way to know
that what was scanned is what is running.
*/}}
{{- define "dotnet-service.image" -}}
{{- if not .Values.image.repository -}}
{{- fail "image.repository is required" -}}
{{- end -}}
{{- if .Values.image.digest -}}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest -}}
{{- else if .Values.image.tag -}}
{{- printf "%s:%s" .Values.image.repository .Values.image.tag -}}
{{- else -}}
{{- printf "%s:%s" .Values.image.repository .Chart.AppVersion -}}
{{- end -}}
{{- end }}
