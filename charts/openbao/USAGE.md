# OpenBao Usage Guide

This guide covers day-to-day use of the `openbao.example.org` OpenBao deployment: login, key/value secrets, database dynamic credentials, database static credentials, and rotation.

Commands assume:

```bash
export BAO_ADDR=https://openbao.example.org
```

Use real service names, database names, users, and policies for your environment. Do not paste production credentials into shell history on shared systems.

## Login

Interactive CLI login:

```bash
bao login -method=oidc -path=oidc role=default
bao login -method=oidc -path=oidc role=adminuser-admin
```

Headless CLI login:

```bash
bao login -method=oidc -path=oidc role=default-device callbackmode=device
bao login -method=oidc -path=oidc role=adminuser-admin-device callbackmode=device
```

The device flow prints a URL and user code. Open the URL on a browser-capable machine, enter the code, finish Keycloak login, and return to the terminal.

Confirm the resulting token:

```bash
bao token lookup
```

## Key/Value Secrets

Use the KV v2 secrets engine for static application secrets such as API keys, service passwords, and configuration values that cannot be generated dynamically.

Enable a KV v2 mount once:

```bash
bao secrets enable -path=kv kv-v2
```

If the mount already exists, this command will fail harmlessly. Check enabled mounts:

```bash
bao secrets list
```

Add or update a secret:

```bash
bao kv put kv/apps/myapp/config \
  api_url="https://api.example.org" \
  api_token="<TOKEN>" \
  db_host="db.example.org"
```

Read the full secret:

```bash
bao kv get kv/apps/myapp/config
```

Read a single field for scripts:

```bash
bao kv get -field=api_token kv/apps/myapp/config
```

Patch one field without replacing the whole secret:

```bash
bao kv patch kv/apps/myapp/config api_token="<NEW_TOKEN>"
```

List secrets under a path:

```bash
bao kv list kv/apps/
bao kv list kv/apps/myapp/
```

Read an older version:

```bash
bao kv get -version=1 kv/apps/myapp/config
```

Delete the latest version:

```bash
bao kv delete kv/apps/myapp/config
```

Undelete a version:

```bash
bao kv undelete -versions=1 kv/apps/myapp/config
```

Permanently destroy a version:

```bash
bao kv destroy -versions=1 kv/apps/myapp/config
```

Delete all metadata and versions for a secret:

```bash
bao kv metadata delete kv/apps/myapp/config
```

KV secrets do not rotate automatically unless you build automation around `bao kv patch` or `bao kv put`. Prefer the database secrets engine for database passwords when OpenBao can manage the database user lifecycle.

## Policies For KV Access

KV v2 policy paths use `/data/` and `/metadata/` even though the CLI path is `kv/apps/...`.

Example read-only policy for one app:

```hcl
path "kv/data/apps/myapp/*" {
  capabilities = ["read"]
}

path "kv/metadata/apps/myapp/*" {
  capabilities = ["list", "read"]
}
```

Example write policy for one app:

```hcl
path "kv/data/apps/myapp/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "kv/metadata/apps/myapp/*" {
  capabilities = ["list", "read", "delete"]
}
```

Write a policy:

```bash
bao policy write myapp-kv-read myapp-kv-read.hcl
bao policy read myapp-kv-read
```

Attach policies through your OIDC role configuration or another auth method.

## Database Secrets Overview

The database secrets engine can generate database credentials on demand and revoke them when the lease expires. Use this instead of storing long-lived database passwords in KV when possible.

Enable the database engine once:

```bash
bao secrets enable database
```

If it already exists, check it with:

```bash
bao secrets list
```

Use a dedicated database admin user for OpenBao. Do not use the actual database root account. After configuring a connection, rotate that OpenBao admin password so only OpenBao knows it:

```bash
bao write -force database/rotate-root/<connection-name>
```

Dynamic database credentials are read from:

```bash
bao read database/creds/<role-name>
```

The output includes a `lease_id`, `username`, `password`, and lease duration. Renew or revoke a dynamic credential:

```bash
bao lease renew <LEASE_ID>
bao lease revoke <LEASE_ID>
```

Revoke every active lease for a role:

```bash
bao lease revoke -prefix database/creds/<role-name>
```

## MySQL Or MariaDB Dynamic Credentials

Configure a MySQL connection:

```bash
bao write database/config/mysql-app \
  plugin_name="mysql-database-plugin" \
  connection_url="{{username}}:{{password}}@tcp(mysql.example.org:3306)/" \
  allowed_roles="mysql-app-readonly" \
  username="openbao_admin" \
  password="<OPENBAO_ADMIN_PASSWORD>"
```

Rotate the OpenBao database admin password:

```bash
bao write -force database/rotate-root/mysql-app
```

Create a dynamic read-only role:

```bash
bao write database/roles/mysql-app-readonly \
  db_name="mysql-app" \
  creation_statements="CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}'; GRANT SELECT ON appdb.* TO '{{name}}'@'%';" \
  default_ttl="1h" \
  max_ttl="24h"
```

Get dynamic credentials:

```bash
bao read database/creds/mysql-app-readonly
```

Use the returned credentials:

```bash
mysql -h mysql.example.org -u '<USERNAME>' -p appdb
```

## PostgreSQL Dynamic Credentials

Configure a PostgreSQL connection:

```bash
bao write database/config/postgres-app \
  plugin_name="postgresql-database-plugin" \
  allowed_roles="postgres-app-readonly" \
  connection_url="postgresql://{{username}}:{{password}}@postgres.example.org:5432/appdb?sslmode=require" \
  username="openbao_admin" \
  password="<OPENBAO_ADMIN_PASSWORD>" \
  password_authentication="scram-sha-256"
```

Rotate the OpenBao database admin password:

```bash
bao write -force database/rotate-root/postgres-app
```

Create a dynamic read-only role:

```bash
bao write database/roles/postgres-app-readonly \
  db_name="postgres-app" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT CONNECT ON DATABASE appdb TO \"{{name}}\"; GRANT USAGE ON SCHEMA public TO \"{{name}}\"; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="24h"
```

Get dynamic credentials:

```bash
bao read database/creds/postgres-app-readonly
```

Use the returned credentials:

```bash
PGPASSWORD='<PASSWORD>' psql \
  --host=postgres.example.org \
  --username='<USERNAME>' \
  --dbname=appdb
```

## MongoDB Dynamic Credentials

OpenBao 2.5.x documentation does not list MongoDB in the current OpenBao database capability table. Use this section only if `mongodb-database-plugin` is available in your OpenBao deployment, for example as a registered external plugin or compatible built-in plugin.

Check plugin availability:

```bash
bao plugin info database mongodb-database-plugin
```

Configure a MongoDB connection:

```bash
bao write database/config/mongodb-app \
  plugin_name="mongodb-database-plugin" \
  allowed_roles="mongodb-app-readwrite" \
  connection_url="mongodb://{{username}}:{{password}}@mongodb.example.org:27017/admin?tls=true" \
  username="openbao_admin" \
  password="<OPENBAO_ADMIN_PASSWORD>"
```

Rotate the OpenBao database admin password:

```bash
bao write -force database/rotate-root/mongodb-app
```

Create a dynamic role:

```bash
bao write database/roles/mongodb-app-readwrite \
  db_name="mongodb-app" \
  creation_statements='{ "db": "admin", "roles": [{ "role": "readWrite", "db": "appdb" }] }' \
  default_ttl="1h" \
  max_ttl="24h"
```

Get dynamic credentials:

```bash
bao read database/creds/mongodb-app-readwrite
```

Use the returned credentials:

```bash
mongosh "mongodb://<USERNAME>:<PASSWORD>@mongodb.example.org:27017/appdb?authSource=admin&tls=true"
```

If `bao plugin info database mongodb-database-plugin` fails because the plugin is missing, install and register the MongoDB database plugin before configuring this connection, or store MongoDB credentials in KV as a temporary fallback.

## Static Database Roles

Dynamic credentials are preferred. Use static roles only when an application must use a fixed database username and OpenBao should rotate that user's password.

Create or update a static role:

```bash
bao write database/static-roles/mysql-app-user \
  db_name="mysql-app" \
  username="app_user" \
  rotation_period="24h"
```

Read the current password:

```bash
bao read database/static-creds/mysql-app-user
```

Manually rotate the static user's password:

```bash
bao write -force database/rotate-role/mysql-app-user
```

Static roles rotate automatically after `rotation_period`. Applications must reread `database/static-creds/<role-name>` when the password changes.

Do not create a static role for the same OpenBao database admin user configured under `database/config/<connection-name>`. Rotating that user as a static role can break OpenBao's ability to manage dynamic and static users.

## Database Policies

Application policy for one dynamic database role:

```hcl
path "database/creds/mysql-app-readonly" {
  capabilities = ["read"]
}
```

Application policy for one static database role:

```hcl
path "database/static-creds/mysql-app-user" {
  capabilities = ["read"]
}
```

Operator policy for managing one database connection and its roles:

```hcl
path "database/config/mysql-app" {
  capabilities = ["create", "read", "update", "delete"]
}

path "database/rotate-root/mysql-app" {
  capabilities = ["update"]
}

path "database/roles/mysql-app-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "database/static-roles/mysql-app-*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "database/rotate-role/mysql-app-*" {
  capabilities = ["update"]
}
```

## Secret Rotation Checklist

For KV secrets:

1. Update the upstream credential or API token.
2. Write the new value with `bao kv patch` or `bao kv put`.
3. Restart or signal consumers that cache the value.
4. Verify the application can use the new value.
5. Revoke the old upstream credential.

For dynamic database credentials:

1. Keep TTLs short enough for the application risk profile.
2. Let leases expire naturally, or revoke a specific lease with `bao lease revoke`.
3. Use `bao lease revoke -prefix database/creds/<role-name>` for emergency mass revocation.
4. Read `database/creds/<role-name>` again to get a fresh username and password.

For database admin credentials held by OpenBao:

1. Confirm the configured database admin user is dedicated to OpenBao.
2. Run `bao write -force database/rotate-root/<connection-name>`.
3. Do not expect to retrieve the rotated admin password from OpenBao.
4. Verify dynamic credential generation still works.

For static database roles:

1. Set a `rotation_period`.
2. Consumers read `database/static-creds/<role-name>`.
3. Trigger emergency rotation with `bao write -force database/rotate-role/<role-name>`.
4. Restart or reload consumers that cache the password.

## Useful Inspection Commands

```bash
bao status
bao auth list
bao secrets list
bao policy list
bao kv metadata get kv/apps/myapp/config
bao list database/config
bao list database/roles
bao list database/static-roles
bao read database/config/mysql-app
bao read database/roles/mysql-app-readonly
```

## References

- OpenBao KV secrets engine: https://openbao.org/docs/secrets/kv/
- OpenBao KV v2 secrets engine: https://openbao.org/docs/secrets/kv/kv-v2/
- OpenBao database secrets engine: https://openbao.org/docs/secrets/databases/
- OpenBao database secrets API: https://openbao.org/api-docs/secret/databases/
- OpenBao MySQL/MariaDB database plugin: https://openbao.org/docs/secrets/databases/mysql-maria/
- OpenBao PostgreSQL database plugin: https://openbao.org/docs/secrets/databases/postgresql/
- HashiCorp Vault MongoDB database plugin reference for compatible plugin behavior: https://developer.hashicorp.com/vault/docs/secrets/databases/mongodb
