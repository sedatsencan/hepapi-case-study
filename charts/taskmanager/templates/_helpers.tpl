{{/*
Chart name, overridable.
*/}}
{{- define "taskmanager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified name, used for every resource this chart owns.
*/}}
{{- define "taskmanager.fullname" -}}
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

{{- define "taskmanager.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Labels applied to every object.
*/}}
{{- define "taskmanager.labels" -}}
helm.sh/chart: {{ include "taskmanager.chart" . }}
{{ include "taskmanager.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: taskmanager
{{- end -}}

{{/*
Selector labels. Deliberately limited to name and instance: these end up in the
Deployment's matchLabels, which is immutable, so including the chart or app
version here would make every version bump fail on upgrade.
*/}}
{{- define "taskmanager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "taskmanager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "taskmanager.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "taskmanager.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "taskmanager.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{/*
Comma-separated list of every replica set member, as
<statefulset>-<ordinal>.<headless>.<namespace>.svc.cluster.local:<port>.
Single source of truth for the connection string.
*/}}
{{- define "taskmanager.database.members" -}}
{{- $root := . -}}
{{- $members := list -}}
{{- range $ordinal := until (int .Values.database.replicaCount) -}}
{{- $member := printf "%s-%d.%s.%s.svc.cluster.local:%v"
      $root.Values.database.statefulSetName
      $ordinal
      $root.Values.database.headlessService
      $root.Release.Namespace
      $root.Values.database.port -}}
{{- $members = append $members $member -}}
{{- end -}}
{{- join "," $members -}}
{{- end -}}

{{/*
Host the entrypoint waits on before starting the application. The headless
Service resolves to the member pods, so this succeeds as soon as any member is
accepting connections.
*/}}
{{- define "taskmanager.database.waitHost" -}}
{{- printf "%s.%s.svc.cluster.local" .Values.database.headlessService .Release.Namespace -}}
{{- end -}}

{{- define "taskmanager.secretName" -}}
{{- default (include "taskmanager.fullname" .) .Values.appSecret.existingSecret -}}
{{- end -}}

{{/*
Flask's SECRET_KEY, already base64 encoded for the Secret.

Reuses the value stored in the cluster when there is one. Regenerating it on
every upgrade would invalidate the signature on every outstanding Flask-WTF
CSRF token, so every open browser tab would start rejecting form submissions.
lookup returns nothing during `helm template` and `--dry-run`, which only means
a throwaway value appears in rendered output.
*/}}
{{- define "taskmanager.secretKey" -}}
{{- $existing := lookup "v1" "Secret" .Release.Namespace (include "taskmanager.fullname" .) -}}
{{- if and $existing $existing.data (index $existing.data .Values.appSecret.key) -}}
{{- index $existing.data .Values.appSecret.key -}}
{{- else -}}
{{- randAlphaNum 48 | b64enc -}}
{{- end -}}
{{- end -}}
