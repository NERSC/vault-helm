{{/*
Expand the parent chart name.
*/}}
{{- define "openbao-wrapper.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified name for local wrapper resources.
*/}}
{{- define "openbao-wrapper.fullname" -}}
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

{{- define "openbao-wrapper.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "openbao-wrapper.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openbao-wrapper.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "openbao-wrapper.labels" -}}
helm.sh/chart: {{ include "openbao-wrapper.chart" . }}
{{ include "openbao-wrapper.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "openbao-wrapper.acmeWebsrvName" -}}
{{- if .Values.tlsAcme.webServer.existing -}}
{{- .Values.tlsAcme.webServer.deploymentName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-acme-websrv" (include "openbao-wrapper.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "openbao-wrapper.acmeServiceName" -}}
{{- if .Values.tlsAcme.webServer.existing -}}
{{- default .Values.tlsAcme.webServer.deploymentName .Values.tlsAcme.webServer.serviceName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "openbao-wrapper.acmeWebsrvName" . -}}
{{- end -}}
{{- end -}}

{{- define "openbao-wrapper.acmeClaimName" -}}
{{- if .Values.tlsAcme.webServer.existing -}}
{{- .Values.tlsAcme.webServer.claimName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-acme-webroot" (include "openbao-wrapper.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "openbao-wrapper.ingressHosts" -}}
{{- $hosts := list -}}
{{- range .Values.ingress.userDomains -}}
{{- $hosts = append $hosts . -}}
{{- end -}}
{{- if .Values.ingress.spinDomain -}}
{{- $hosts = append $hosts .Values.ingress.spinDomain -}}
{{- end -}}
{{- toYaml $hosts -}}
{{- end -}}

{{- define "openbao-wrapper.tlsHosts" -}}
{{- $hosts := .Values.ingress.tls.hosts | default .Values.ingress.userDomains -}}
{{- toYaml $hosts -}}
{{- end -}}

{{- define "openbao-wrapper.acmeImage" -}}
{{- printf "%s:%s" .Values.tlsAcme.image.repository (.Values.tlsAcme.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{- define "openbao-wrapper.oidcBootstrapImage" -}}
{{- printf "%s:%s" .Values.oidc.bootstrap.image.repository (.Values.oidc.bootstrap.image.tag | default .Chart.AppVersion) -}}
{{- end -}}

{{- define "openbao-wrapper.gen-certs" -}}
{{- $altNames := list -}}
{{- range .Values.ingress.userDomains -}}
{{- $altNames = append $altNames . -}}
{{- end -}}
{{- if .Values.ingress.spinDomain -}}
{{- $altNames = append $altNames .Values.ingress.spinDomain -}}
{{- end -}}
{{- $ca := genCA "openbao-placeholder-ca" 365 -}}
{{- $cert := genSignedCert (first $altNames | default "openbao.example.org") nil $altNames 365 $ca -}}
tls.crt: {{ $cert.Cert | b64enc }}
tls.key: {{ $cert.Key | b64enc }}
{{- end -}}
