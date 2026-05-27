# OpenBao Helm Wrapper

This chart deploys OpenBao into Kubernetes with site defaults for the `vault` namespace, TLS ACME renewal, and optional Keycloak OIDC bootstrap.

For day-to-day instructions on using OpenBao, storing KV secrets, configuring database credentials, and rotating secrets, see [USAGE.md](USAGE.md).

The chart wraps the official OpenBao chart:

- repository: `https://openbao.github.io/openbao-helm`
- chart version: `0.27.2`
- app version: `2.5.3`

## Defaults

- Release name: `openbao`
- Namespace: `vault`
- Public URL: `https://openbao.example.org`
- CNAME target: `openbao.vault.example.internal`
- Ingress name: `openbao`
- Ingress class: `nginx`
- TLS Secret: `tls-cert`
- Storage class: `standard`
- OpenBao data PVC size: `10Gi`
- ACME account email: `admin@example.org`
- ACME image: `ghcr.io/dingp/acme:latest`
- Workload UID/GID: `1000`
- Container capabilities: drop `ALL`

The default OpenBao mode is standalone with file storage. This is suitable for the current development deployment, not a hardened HA production setup.

## Dependencies

Fetch the OpenBao chart dependency:

```bash
helm dependency update charts/openbao
```

If the network is unavailable, this step must be run from an environment that can reach GitHub and `https://openbao.github.io/openbao-helm`.

## Required Secrets

Create the Keycloak OIDC client secret after creating the Keycloak client:

```bash
kubectl -n vault create secret generic openbao-oidc-client \
  --from-literal=client-secret='<KEYCLOAK_CLIENT_SECRET>'
```

Create the OpenBao bootstrap token Secret only after OpenBao is initialized and unsealed:

```bash
kubectl -n vault create secret generic openbao-bootstrap-token \
  --from-literal=token='<OPENBAO_ADMIN_OR_BOOTSTRAP_TOKEN>'
```

The ACME CronJob expects a kubeconfig Secret named `kubeconfig`:

```bash
kubectl -n vault create secret generic kubeconfig \
  --from-file=kubeconfig='<PATH_TO_KUBECONFIG>'
```

Do not commit any of these secret values.

## Keycloak Client

Create a confidential OpenID Connect client in realm `amsc`.

Recommended settings:

- Client ID: `openbao`
- Client authentication: `On`
- Standard flow: `On`
- Direct access grants: `Off`
- Valid redirect URIs:
  - `https://openbao.example.org/v1/auth/oidc/*`
  - `https://openbao.example.org/ui/vault/auth/oidc/oidc/callback`
  - `http://localhost:8250/oidc/callback`
- Web origins:
  - `https://openbao.example.org`

The OIDC bootstrap uses issuer/discovery URL:

```text
https://oidc.example.org/realms/amsc
```

The default OIDC role receives `openbao-reader`. Elevated roles grant `openbao-admin` to user claim value `admin@example.org` and group claim value `openbao-admins`.

The `default` and `adminuser-admin` roles do not require a `groups` claim. The `openbao-admins` role does require Keycloak to emit a `groups` claim containing `openbao-admins`. If Keycloak does not include this claim, add a client mapper or client scope mapper that writes group membership to the ID token with claim name `groups`.

## Install

The namespace should already exist and be managed outside this chart:

```bash
kubectl get namespace vault
```

Install OpenBao first without OIDC bootstrap. This allows the server to start so it can be initialized and unsealed:

```bash
helm upgrade --install openbao charts/openbao \
  --namespace vault
```

Check status:

```bash
kubectl -n vault get pods,svc,ingress,pvc
kubectl -n vault logs statefulset/openbao
```

Initialize and unseal OpenBao according to your operational process. Then create `openbao-bootstrap-token` and run an upgrade with the development values to execute the OIDC bootstrap hook:

```bash
helm upgrade --install openbao charts/openbao \
  --namespace vault \
  -f charts/openbao/values-development.yaml
```

## Auto-Unseal

Auto-unseal is disabled by default. The default deployment uses Shamir unseal keys, so an operator must manually unseal OpenBao after pod restarts.

The chart supports explicit auto-unseal configuration through `openbao.autoUnseal`. For production, prefer an external trust source such as AWS KMS, GCP Cloud KMS, Azure Key Vault, PKCS#11, KMIP, OCI KMS, or a separate OpenBao transit instance. Static seal with a Kubernetes Secret is operationally simple, but it is weaker than KMS/HSM-backed seal because anyone who can read both the OpenBao PVC and the static seal Secret can decrypt the instance.

### Static Auto-Unseal

Generate a 32-byte key and store it in a Kubernetes Secret:

```bash
openssl rand -base64 32

kubectl -n vault create secret generic openbao-static-seal \
  --from-literal=OPENBAO_STATIC_SEAL_KEY='<BASE64_32_BYTE_KEY>'
```

The example values file `charts/openbao/values-auto-unseal-static.example.yaml` enables static auto-unseal and wires the Secret into the OpenBao container:

```yaml
openbao:
  autoUnseal:
    static:
      enabled: true
      currentKeyId: "2026-05-27-1"
      keyEnvVar: OPENBAO_STATIC_SEAL_KEY

  server:
    extraSecretEnvironmentVars:
      - envName: OPENBAO_STATIC_SEAL_KEY
        secretName: openbao-static-seal
        secretKey: OPENBAO_STATIC_SEAL_KEY
```

Apply the values:

```bash
helm upgrade --install openbao charts/openbao \
  --namespace vault \
  -f charts/openbao/values-development.yaml \
  -f charts/openbao/values-auto-unseal-static.example.yaml
```

The OpenBao StatefulSet uses `OnDelete`, so restart the pod to use the new server configuration:

```bash
kubectl -n vault delete pod openbao-0
```

Migrate from Shamir to auto-unseal by entering the existing Shamir unseal keys. Run this until the threshold is satisfied:

```bash
kubectl -n vault exec -it openbao-0 -- bao operator unseal -migrate
```

For the current `5` shares / `3` threshold deployment, run it three times with three different existing unseal keys. Keep the old Shamir keys until migration and restart validation are complete.

Validate auto-unseal:

```bash
kubectl -n vault exec openbao-0 -- bao status
kubectl -n vault delete pod openbao-0
kubectl -n vault get pod openbao-0
kubectl -n vault exec openbao-0 -- bao status
```

After the restart, `bao status` should show `Sealed false` without manual key entry.

### Other Seal Backends

For a production-oriented seal backend, set `openbao.autoUnseal.rawConfig` to the complete OpenBao `seal` stanza and provide any required credentials through `openbao.server.extraSecretEnvironmentVars`, mounted files, workload identity, or the cloud provider's native identity mechanism.

Example shape:

```yaml
openbao:
  autoUnseal:
    rawConfig: |
      seal "awskms" {
        region     = "us-west-2"
        kms_key_id = "<KMS_KEY_ID>"
      }
```

## TLS ACME

TLS ACME renewal is enabled by default. The CronJob:

- uses image `ghcr.io/dingp/acme:latest`
- sets `EMAIL=admin@example.org`
- sets `DOMAIN=openbao.example.org`
- updates Secret `tls-cert`
- targets Ingress `openbao`
- uses kubeconfig Secret `kubeconfig`

The default chart-created webroot resources use storage class `standard` and UID/GID `1000`. To use an existing webroot PVC, set:

```yaml
tlsAcme:
  webServer:
    existing: true
    deploymentName: existing-websrv
    serviceName: existing-websrv
    claimName: pvc-existing-webroot
```

Inspect ACME resources:

```bash
kubectl -n vault get cronjob openbao-acme-renew
kubectl -n vault get secret tls-cert
```

Run a one-off renewal job if needed:

```bash
kubectl -n vault create job --from=cronjob/openbao-acme-renew openbao-acme-renew-manual
kubectl -n vault logs job/openbao-acme-renew-manual
```

## Validation

Lint and render:

```bash
helm lint charts/openbao
helm template openbao charts/openbao --namespace vault
helm template openbao charts/openbao --namespace vault -f charts/openbao/values-development.yaml
helm template openbao charts/openbao --namespace vault \
  -f charts/openbao/values-development.yaml \
  -f charts/openbao/values-auto-unseal-static.example.yaml
```

Dry-run an upgrade against the cluster:

```bash
helm upgrade --install openbao charts/openbao \
  --namespace vault \
  -f charts/openbao/values-development.yaml \
  --dry-run
```

Check OIDC bootstrap logs:

```bash
kubectl -n vault logs job/openbao-oidc-bootstrap
```

Read OIDC configuration from OpenBao:

```bash
export BAO_ADDR=https://openbao.example.org
bao auth list
bao read auth/oidc/config
bao read auth/oidc/role/default
bao read auth/oidc/role/adminuser-admin
bao read auth/oidc/role/openbao-admins
```

Test UI login at:

```text
https://openbao.example.org
```

Test CLI login:

```bash
bao login -method=oidc role=default
bao login -method=oidc role=adminuser-admin
bao login -method=oidc role=openbao-admins
```

If login fails with `failed to fetch groups: "groups" claim not found in token`, use `role=default` or `role=adminuser-admin`, or update the Keycloak `openbao` client to include a `groups` claim before using `role=openbao-admins`.

### Headless CLI Login

Use the device-flow roles from terminals that cannot open a browser or listen on localhost:

```bash
bao login -method=oidc -path=oidc role=default-device callbackmode=device
bao login -method=oidc -path=oidc role=adminuser-admin-device callbackmode=device
bao login -method=oidc -path=oidc role=openbao-admins-device callbackmode=device
```

The OpenBao role must be configured with `callback_mode: device`; using `callbackmode=device` with a normal client-callback role can fail with `no state returned in device callback mode`.

Enable the OAuth 2.0 Device Authorization Grant on the Keycloak `openbao` client before using these roles.

## Rollback And Uninstall

Rollback:

```bash
helm -n vault history openbao
helm -n vault rollback openbao <REVISION>
```

Uninstall:

```bash
helm -n vault uninstall openbao
```

PVCs and OpenBao configuration stored inside OpenBao may remain after uninstall. Remove them manually only when intentionally retiring the deployment.

## Production Hardening Follow-ups

- Move from standalone file storage to an HA design.
- Define backup and restore procedures.
- Decide on unseal strategy.
- Add monitoring and alerting.
- Review admin policy scope before granting more users or groups elevated access.
