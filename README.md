# Vault Helm

This repository contains a Helm wrapper chart for deploying OpenBao with ingress, TLS ACME renewal, optional OIDC bootstrap, and optional auto-unseal configuration.

The chart lives in:

```text
charts/openbao
```

Before installing it in a new environment, review and change the values below. The defaults are examples, not production-ready universal settings.

## Required Changes

### Public URL And Ingress

Update these values in `charts/openbao/values.yaml` or an environment-specific override file:

```yaml
publicUrl: https://openbao.example.org

ingress:
  enabled: true
  className: nginx
  userDomains:
    - openbao.example.org
  spinDomain: openbao.vault.example.internal
  tls:
    secretName: tls-cert
```

Change:

- `publicUrl`
- `ingress.userDomains`
- `ingress.spinDomain`, or remove it if you do not use a second internal/CNAME target
- `ingress.className`
- `ingress.tls.secretName`

### OIDC Provider

Update the OIDC issuer, client, redirect URIs, and admin bindings:

```yaml
oidc:
  discoveryUrl: https://oidc.example.org/realms/amsc
  clientId: openbao
  allowedRedirectUris:
    - https://openbao.example.org/ui/vault/auth/oidc/oidc/callback
    - https://openbao.example.org/v1/auth/oidc/oidc/callback
    - http://localhost:8250/oidc/callback
```

Create a confidential OIDC client in your identity provider with matching redirect URIs. Store its client secret in Kubernetes:

```bash
kubectl -n vault create secret generic openbao-oidc-client \
  --from-literal=client-secret='<OIDC_CLIENT_SECRET>'
```

Update admin role bindings:

```yaml
oidc:
  roles:
    - name: adminuser-admin
      boundClaims:
        preferred_username: admin@example.org
    - name: openbao-admins
      boundClaims:
        groups: openbao-admins
```

Change the claim names and values to match your identity provider. For Keycloak group claims, disable full group path if you want the emitted value to be `openbao-admins` instead of `/openbao-admins`.

### Storage

Update the storage class and size:

```yaml
openbao:
  server:
    dataStorage:
      storageClass: standard
      size: 10Gi
```

For production, decide on HA storage, backup, restore, and disaster recovery before storing critical secrets.

### UID/GID And Security Context

The example values use UID/GID `1000`:

```yaml
securityDefaults:
  uid: 1000
  gid: 1000
```

Change every rendered workload UID/GID if your cluster requires a project-specific UID, supplemental group, or PVC ownership model.

### TLS ACME

If you use the bundled ACME CronJob, update:

```yaml
tlsAcme:
  enabled: true
  email: admin@example.org
  image:
    repository: ghcr.io/dingp/acme
    tag: latest
  kubeconfig:
    secretName: kubeconfig
```

Create the kubeconfig Secret expected by the ACME job:

```bash
kubectl -n vault create secret generic kubeconfig \
  --from-file=kubeconfig='<PATH_TO_KUBECONFIG>'
```

Disable `tlsAcme.enabled` if your cluster uses cert-manager or another certificate controller.

### Auto-Unseal

Auto-unseal is disabled by default. For a simple static-seal setup, use:

```bash
openssl rand -base64 32

kubectl -n vault create secret generic openbao-static-seal \
  --from-literal=OPENBAO_STATIC_SEAL_KEY='<BASE64_32_BYTE_KEY>'
```

Then apply:

```bash
helm upgrade --install openbao charts/openbao \
  --namespace vault \
  -f charts/openbao/values-development.yaml \
  -f charts/openbao/values-auto-unseal-static.example.yaml
```

If migrating an already initialized Shamir-sealed deployment, restart the pod and run:

```bash
kubectl -n vault exec -it openbao-0 -- bao operator unseal -migrate
```

Run that with enough existing Shamir unseal keys to satisfy the threshold.

Static auto-unseal is convenient, but weaker than KMS/HSM-backed seal. For production, prefer an external trust source such as cloud KMS, PKCS#11, KMIP, OCI KMS, or a separate OpenBao transit instance.

## Install Flow

1. Create or confirm the namespace:

```bash
kubectl get namespace vault
```

2. Fetch dependencies:

```bash
helm dependency update charts/openbao
```

3. Render and lint:

```bash
helm lint charts/openbao
helm template openbao charts/openbao --namespace vault -f charts/openbao/values-development.yaml
```

4. Install OpenBao:

```bash
helm upgrade --install openbao charts/openbao \
  --namespace vault \
  -f charts/openbao/values-development.yaml
```

5. Initialize and unseal OpenBao.

6. Create the OIDC client secret and a temporary bootstrap/admin token Secret.

7. Re-run the Helm upgrade with OIDC bootstrap enabled.

8. Delete the temporary bootstrap token Secret.

## Documentation

More detailed chart documentation:

```text
charts/openbao/README.md
```

OpenBao usage guide:

```text
charts/openbao/USAGE.md
```
