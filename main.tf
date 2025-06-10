locals {
  id_prefix = "pgcompanion-"
  res_id    = "pgcompanion"
  type      = "pgcompanion-type"
}

variable "ht_token" {
  description = "Humanitec API token"
  type        = string
}

variable "app_name" {
  description = "Name of the Humanitec application"
  type        = string
}

variable "org_id" {
  description = "Humanitec organization ID"
  type        = string
}

variable "env_id" {
  description = "Humanitec environment ID"
  type        = string
  default     = "development"
}

resource "humanitec_application" "app" {
  id   = var.app_name
  name = var.app_name
}

resource "humanitec_environment" "env" {
  app_id = var.app_name
  id     = var.env_id
  name   = var.env_id
  type   = var.env_id

  depends_on = [humanitec_application.app]
}

resource "humanitec_resource_definition" "route_for_pgadmin" {
  id          = "${local.id_prefix}${local.type}-route"
  name        = "${local.id_prefix}${local.type}-route"
  type        = "route"
  driver_type = "humanitec/template"

  driver_inputs = { 
    values_string = jsonencode({
      "pghost" = "$${resources['route.pgadmin>postgres'].outputs.host}"
      "dns" = "$${resources['dns.default#shared.dns'].outputs.host}"

      "templates" = {
        "cookie" = <<EOT
EOT
        "init" = <<EOT
host: {{ .driver.values.dns | quote }}
serviceName: {{ .driver.values.pghost | first | quote }}
EOT
        "outputs" = <<EOT
host: {{ .init.host | quote }}
path: "/pgadmin"
port: "5050"
service: {{ print "pgadmin-" .init.serviceName "-svc" | quote }}
EOT
      }
    })
  }

  force_delete = true
}

resource "humanitec_resource_definition_criteria" "route_for_pgadmin" {
  resource_definition_id = resource.humanitec_resource_definition.route_for_pgadmin.id
  app_id                 = var.app_name
  class                  = "pgadmin"

  force_delete = true
}


resource "humanitec_resource_definition" "pg_with_attached_admin" {
  id          = "${local.id_prefix}${local.type}"
  name        = "${local.id_prefix}${local.type}"
  type        = "postgres"
  driver_type = "humanitec/template"

  driver_inputs = {
    values_string = jsonencode({
      "resId" = "$${context.res.id}"
      "resClass" =  "$${context.res.class}"
      "templates" = {
        "cookie" = <<EOT
name: {{ .init.name }}
port: {{ .init.port }}
user: {{ .init.user }}
password: {{ .init.password }}
database: {{ .init.database }}
EOT
        "init" = <<EOT
{{- if and .cookie .cookie.name }}
name: {{ .cookie.name }}
{{- else }}
# StatefulSets names are limited to 52 chars https://github.com/kubernetes/kubernetes/issues/64023
  {{- if regexMatch "modules\\.[a-z0-9-]+\\.externals" .driver.values.resId }}
name: postgres-{{ index (splitList "." .driver.values.resId) 1 | substr 0 19 }}-{{ index (splitList "." .driver.values.resId) 3 | substr 0 19 }}
  {{- else }}
name: postgres-{{ index (splitList "." .driver.values.resId) 1 | substr 0 38 }}
  {{- end }}
{{- end }}

{{- if and .cookie .cookie.port }}
port: {{ .cookie.port }}
{{- else }}
port: 5432
{{- end }}

{{- if and .cookie .cookie.user }}
user: {{ .cookie.user }}
{{- else }}
user: {{ randAlpha 8 | lower | quote }}
{{- end }}

{{- if and .cookie .cookie.password }}
password: {{ .cookie.password }}
{{- else }}
password: {{ randAlphaNum 16 | quote }}
{{- end }}

{{- if and .cookie .cookie.database }}
database: {{ .cookie.database }}
{{- else }}
database: {{ randAlpha 8 | lower | quote }}
{{- end }}
EOT
        "manifests" = <<EOT
pgadmin-configmap.yaml:
  location: namespace
  data:
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: "pgadmin-{{ .init.name }}-config"
    data:
      servers.json: |
        {
          "Servers": {
            "1": {
              "Name": {{ .init.name | quote }},
              "Group": "Servers",
              "Port": {{ .init.port }},
              "Username": "{{ .init.name }}-pgadmin-user",
              "PasswordExecCommand": "echo $DATABASE_PASSWORD",
              "Host": {{ .init.name | quote }},
              "SSLMode": "prefer",
              "MaintenanceDB": {{ .init.database | quote }}
            }
          }
        }
      pgadmin-init.sql: |
        CREATE ROLE "{{ .init.name }}-pgadmin-user" WITH LOGIN PASSWORD '{{ .init.password }}';
        GRANT ALL PRIVILEGES ON DATABASE {{ .init.database }} TO "{{ .init.name }}-pgadmin-user";
        ALTER ROLE "{{ .init.name }}-pgadmin-user" SUPERUSER;
secret.yaml:
  location: namespace
  data:
    apiVersion: v1
    kind: Secret
    metadata:
      name: {{ .init.name }}
    type: Opaque
    data:
      POSTGRES_PASSWORD: {{ .init.password | b64enc }}
statefulset.yaml:
  location: namespace
  data:
    apiVersion: apps/v1
    kind: StatefulSet
    metadata:
      name: {{ .init.name }}
    spec:
      serviceName: postgres
      selector:
        matchLabels:
          app: {{ .init.name }}
      template:
        metadata:
          labels:
            app: {{ .init.name }}
        spec:
          automountServiceAccountToken: false
          tolerations:
          - effect: NoSchedule
            key: FMGNodeType
            operator: Equal
            value: CoreApps
          containers:
            - name: {{ .init.name }}
              image: postgres:17-alpine
              env:
                - name: POSTGRES_USER
                  value: {{ .init.user | quote }}
                - name: POSTGRES_PASSWORD
                  valueFrom:
                    secretKeyRef:
                      name: {{ .init.name }}
                      key: POSTGRES_PASSWORD
                - name: POSTGRES_DB
                  value: {{ .init.database | quote }}
                - name: PGDATA
                  value: /var/lib/postgresql/data/pgdata
                - name: PGPORT
                  value: {{ .init.port | quote }}
              ports:
                - containerPort: {{ .init.port }}
                  name: postgres
              volumeMounts:
                - name: {{ .init.name }}
                  mountPath: /var/lib/postgresql/data
                - name: pgadmin-{{ .init.name }}-config
                  mountPath: /docker-entrypoint-initdb.d/10-pgadmin-init.sql
                  subPath: pgadmin-init.sql
                  readOnly: true
              securityContext:
                runAsUser: 65532
                runAsGroup: 65532
                allowPrivilegeEscalation: false
                privileged: false
                capabilities:
                  drop:
                    - ALL
          volumes:
          - name: pgadmin-{{ .init.name }}-config
            configMap:
              name: pgadmin-{{ .init.name }}-config
          securityContext:
            runAsNonRoot: true
            fsGroup: 65532
            seccompProfile:
              type: RuntimeDefault
      volumeClaimTemplates:
        - metadata:
            name: {{ .init.name }}
          spec:
            accessModes:
              - ReadWriteOnce
            resources:
              requests:
                storage: 1Gi
service.yaml:
  location: namespace
  data:
    apiVersion: v1
    kind: Service
    metadata:
      name: {{ .init.name }}
    spec:
      ports:
      - port: {{ .init.port }}
      selector:
        app: {{ .init.name }}
      clusterIP: None
pgadmin-secret.yaml:
  location: namespace
  data:
    apiVersion: v1
    kind: Secret
    metadata:
      name: pgadmin-{{ .init.name }}-secret
    type: Opaque
    data:
      pgadminInituserPassword: {{ .init.password | b64enc }}
      pgadminDatabasePassword: {{ .init.password | b64enc }}
pgadmin-service.yaml:
  location: namespace
  data:
    apiVersion: v1
    kind: Service
    metadata:
      name: pgadmin-{{ .init.name }}-svc
    spec:
      ports:
      - protocol: TCP
        port: 5050
        targetPort: http
      selector:
        app: pgadmin-{{ .init.name }}
      type: NodePort
pgadmin-sts.yaml:
  location: namespace
  data:
    apiVersion: apps/v1
    kind: StatefulSet
    metadata:
      name: pgadmin-{{ .init.name }}
    spec:
      serviceName: pgadmin-{{ .init.name }}-svc
      replicas: 1
      selector:
        matchLabels:
          app: pgadmin-{{ .init.name }}
      template:
        metadata:
          labels:
            app: pgadmin-{{ .init.name }}
        spec:
          securityContext:
            fsGroup: 5050
          tolerations:
          - effect: NoSchedule
            key: FMGNodeType
            operator: Equal
            value: CoreApps
          containers:
            - name: pgadmin
              image: dpage/pgadmin4:9
              resources:
                requests:
                  memory: "256Mi"
                  cpu: "250m"
                limits:
                  memory: "512Mi"
                  cpu: "500m"
              env:
              # path prefix for the nginx reverse proxy
              - name: SCRIPT_NAME
                value: /pgadmin
              - name: PGADMIN_LISTEN_PORT
                value: "5050"
              - name: PGADMIN_DEFAULT_EMAIL
                value: admin@FIXME.internal
              - name: PGADMIN_DEFAULT_PASSWORD
                valueFrom:
                  secretKeyRef:
                    name: pgadmin-{{ .init.name }}-secret
                    key: pgadminInituserPassword
              # https://www.pgadmin.org/docs/pgadmin4/latest/config_py.html#config-py
              - name: PGADMIN_CONFIG_UPGRADE_CHECK_ENABLED 
                value: "False"
              - name: PGADMIN_CONFIG_SERVER_MODE
                value: "True"
              - name: PGADMIN_CONFIG_ENHANCED_COOKIE_PROTECTION
                value: "False"
              - name: PGADMIN_CONFIG_ENABLE_PSQL
                value: "True"
              - name: PGADMIN_CONFIG_APP_NAME
                value: "\"Codex PgAdmin - {{ .init.name }}\""
              # https://github.com/pgadmin-org/pgadmin4/issues/6792
              # Required to dynamically get the password from the secret/env variable
              - name: PGADMIN_CONFIG_ENABLE_SERVER_PASS_EXEC_CMD
                value: "True"
              # Database connection details
              - name: DATABASE_PASSWORD
                valueFrom:
                  secretKeyRef:
                    name: pgadmin-{{ .init.name }}-secret
                    key: pgadminDatabasePassword
              # OAUTH2 CONFIG TODO - EntraID
              #  - name: PGADMIN_CONFIG_OAUTH2_CONFIG 
              #    value: "[]"
              #  - name: PGADMIN_CONFIG_AUTHENTICATION_SOURCES
              #    value: "['oauth2', 'internal']"
              ports:
              - name: http
                containerPort: 5050
                protocol: TCP
              volumeMounts:
              - name: pgadmin-{{ .init.name }}-config
                mountPath: /pgadmin4/servers.json
                subPath: servers.json
                readOnly: true
              - name: pgadmin-data
                mountPath: /var/lib/pgadmin
          volumes:
          - name: pgadmin-{{ .init.name }}-config
            configMap:
              name: pgadmin-{{ .init.name }}-config
      volumeClaimTemplates:
      - metadata:
          name: pgadmin-data
        spec:
          accessModes: [ "ReadWriteOnce" ]
          resources:
            requests:
              storage: 3Gi
EOT
        "outputs" = {
          "host": "{{ .init.name | quote }}",
          "port": "{{ .init.port | quote }}",
          "name": "{{ .init.name | quote }}"
        }
        "secrets" = {
          "username": "{{ .init.username | quote }}",
          "password": "{{ .init.password | quote }}"
        }

      }
    })
  }

  provision = {
    "route.pgadmin" = {
      is_dependent = true,
      match_dependents: false
    }
  }

  force_delete = true
}

resource "humanitec_resource_definition_criteria" "pg_with_attached_admin" {
  resource_definition_id = resource.humanitec_resource_definition.pg_with_attached_admin.id
  app_id                 = var.app_name
  env_type               = var.env_id

  force_delete = true
}
