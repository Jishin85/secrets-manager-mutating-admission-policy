# Secrets Manager Sidecar Injection: MutatingAdmissionPolicy

Kubernetes-native sidecar injection for Palo Alto Networks Idira Secrets
Manager (formerly CyberArk Conjur). It replaces the
[cyberark/sidecar-injector](https://github.com/cyberark/sidecar-injector)
mutating webhook with a set of `MutatingAdmissionPolicy` resources that run as
CEL inside kube-apiserver. There is no server to deploy, no TLS certificate or
CSR to manage, and no network hop on pod creation.

The pod annotation contract (`conjur.org/*`) and the namespace opt-in label
(`cyberark-sidecar-injector=enabled`) are the same as the webhook's. Existing
workloads therefore migrate without manifest changes.

> **Status: tested on Kubernetes 1.36 against Secrets Manager SaaS.**
> Secrets Provider (push-to-file and `k8s_secrets`) and the authenticator
> client were verified end to end with authn-jwt. Secretless and the authn-k8s
> path are covered by mutation tests only. See [Testing](#testing).

## Contents

```
config/sidecar-config.yaml       Namespace + parameter ConfigMap (images, Secrets Manager connection)
policies/secrets-provider.yaml   MutatingAdmissionPolicy + Binding: inject-type secrets-provider
policies/authenticator.yaml      MutatingAdmissionPolicy + Binding: inject-type authenticator
policies/secretless.yaml         MutatingAdmissionPolicy + Binding: inject-type secretless
policies/validation.yaml         ValidatingAdmissionPolicy + Binding: rejects invalid/uninjected pods
examples/                        Annotated sample workloads
docs/sidecar-injector-analysis.md  Study of the webhook and the problems this design fixes
tests/                           Secrets Manager setup, mutation tests and end-to-end tests
kustomization.yaml
```

## Requirements

- **Kubernetes 1.36 or later.** The policies use
  `admissionregistration.k8s.io/v1`, where `MutatingAdmissionPolicy` is GA.
  On 1.34/1.35, change the policy and binding `apiVersion` to `v1beta1` (the
  spec fields are the same) and enable the beta API on kube-apiserver with:
  - `--feature-gates=MutatingAdmissionPolicy=true`
  - `--runtime-config=admissionregistration.k8s.io/v1beta1=true`
- **Native sidecar containers** (`initContainers[].restartPolicy: Always`),
  which are GA since 1.33. Every cluster that supports the policies has them.

## Install

1. Edit `config/sidecar-config.yaml`: pin the images and set the Secrets
   Manager account, appliance URL, authenticator ID and CA certificate. If you
   already have a Golden ConfigMap from the cluster-prep Helm chart, you can
   point `paramRef` in each binding at it instead, because the key names match.
2. Apply:
   ```bash
   kubectl apply -k .
   ```
3. Opt namespaces in:
   ```bash
   kubectl label namespace <app-namespace> cyberark-sidecar-injector=enabled
   ```
4. Annotate pod templates (see [examples/](examples/)).

## Authentication: authn-k8s or authn-jwt

The authentication method follows the parameter ConfigMap's `CONJUR_AUTHN_URL`:

- **Not set:** authn-k8s, at
  `<conjurApplianceUrl>/authn-k8s/<authnK8sAuthenticatorID>`. This needs a
  Secrets Manager instance (for example a Follower) that can reach the
  cluster's API server.
- **Points at `/authn-jwt/<service-id>`:** Secrets Provider and the
  authenticator client get JWT wiring:
  - a projected service account token volume `jwt-token` (audience
    `jwtAudience`, default `conjur`; lifetime `jwtTokenExpirationSeconds`,
    default 600)
  - that token mounted at `/var/run/secrets/tokens`
  - `JWT_TOKEN_PATH` set to it

  This is the only option for **Secrets Manager SaaS**, which cannot reach a
  private cluster. If the cluster's JWKS endpoint isn't public, configure the
  authenticator with static `public-keys` (see
  [tests/setup-conjur.sh](tests/setup-conjur.sh)).

Two cases keep authn-k8s style configuration: authenticator pods that
reference `conjur.org/conjurConnConfig`, and Secretless. Both take their
connection settings from namespace ConfigMaps or literals.

## Annotation reference

Set these on the **pod template**, not on the Deployment or Job.

| Annotation | Applies to | Description | Default |
|---|---|---|---|
| `conjur.org/inject` | all | `true` (`y`, `yes`, `on`) enables injection | required |
| `conjur.org/inject-type` | all | `secrets-provider`, `authenticator` or `secretless` | required |
| `conjur.org/container-mode` | secrets-provider, authenticator | `init`: regular init container. `sidecar`: native sidecar | `sidecar` |
| `conjur.org/container-name` | secrets-provider, authenticator | Injected container name | `cyberark-secrets-provider-for-k8s` / `authenticator` |
| `conjur.org/container-image` | all | Per-pod image override | from parameter ConfigMap |
| `conjur.org/conjur-inject-volumes` | secrets-provider, authenticator | Comma-separated app containers that receive the shared volumes | none |
| `conjur.org/secrets-destination` | secrets-provider | `file` or `k8s_secrets` | `file` |
| `conjur.org/authn-identity` | all | Host identity. Read by Secrets Provider; used as `CONJUR_AUTHN_LOGIN` for authenticator/secretless when there is no `conjurAuthConfig` | none |
| `conjur.org/conjurConnConfig` | authenticator, secretless | Namespace ConfigMap with `CONJUR_*` connection keys | cluster parameters |
| `conjur.org/conjurAuthConfig` | authenticator, secretless | Namespace ConfigMap with `CONJUR_AUTHN_LOGIN` | `conjur.org/authn-identity` |
| `conjur.org/secretless-config` | secretless | `<configmap>`, `configfile#<configmap>` or `k8s/crd#<name>` | required |
| `conjur.org/secretless-CRD-suffix` | secretless | Sets `SECRETLESS_CRD_SUFFIX` | none |

After injection the pod carries `conjur.org/status: injected`. As with the
webhook, the injector-only annotations are removed (`inject`, `inject-type`,
`container-name`, `container-image`, `conjur-inject-volumes`,
`conjurConnConfig`, `conjurAuthConfig`, `secretless-config`,
`secretless-CRD-suffix`). For Secrets Provider, `container-mode` and
`secrets-destination` are written back with their resolved values, so the
sidecar reads the same configuration the policy acted on.

## Changes from the webhook

These are deliberate changes, and they are what make this the new standard:

- **Native sidecars.** "Sidecar" mode now injects an init container with
  `restartPolicy: Always`, inserted first in `initContainers`. This has three
  effects:
  - The sidecar starts before the application and stops after it.
  - Jobs complete.
  - For Secrets Provider, a `postStart` hook
    (`/usr/local/bin/conjur-secrets-provided.sh`) holds back the application
    containers until secrets are present. This solves the ordering problem
    left open in the webhook's GA design doc.
- **Defaults for missing annotations.** Secrets Provider gets a default
  container name. `conjur-secrets` mounts are no longer added in
  `k8s_secrets` mode. Volumes that already exist are reused instead of
  duplicated.
- **Service account token.** Secrets Provider and Secretless get the pod's
  service account token mounted. This is needed because the ServiceAccount
  admission plugin runs before admission policies.
- **No per-namespace ConfigMaps needed** for the authenticator and Secretless.
  They fall back to the cluster parameter ConfigMap. Referencing namespace
  ConfigMaps still works exactly as before.
- **Hardened containers.** Injected containers get
  `allowPrivilegeEscalation: false`, drop all capabilities and use the
  `RuntimeDefault` seccomp profile. The default `imagePullPolicy` is
  `IfNotPresent` (configurable).
- **Fail-closed validation that doesn't block other pods.** If a pod requests
  injection but is not mutated, `ValidatingAdmissionPolicy` rejects it with a
  reason. Causes include invalid annotations, a missing binding, a missing
  parameter ConfigMap, or the API being disabled. Previously such pods could
  start without secrets.

  The bindings use `parameterNotFoundAction: Allow`. Kubernetes resolves
  parameters before `matchConditions`, so `Deny` would block every pod in a
  labelled namespace whenever the parameter ConfigMap was missing.
- **authn-jwt support** (see above).
- **Legacy (non-native) sidecar placement in `containers` is not offered.**

## Migrating from the webhook

The webhook and the policies can run side by side during a cutover.
Admission policies run before admission webhooks. After a policy injects a
pod, it sets `conjur.org/status: injected` and removes `conjur.org/inject`,
and the webhook skips pods in that state.

1. Install this project (see [Install](#install)).
2. Roll a test workload in a labelled namespace. Confirm the pod has the
   injected init container and `conjur.org/status: injected`.
3. Uninstall the webhook: `helm uninstall <release> -n injectors`. Then delete
   its CSR (`kubectl delete csr cyberark-sidecar-injector.injectors`) and its
   namespace.

## Testing

[tests/](tests/) contains a complete, re-runnable test setup. All names come
from `tests/env` (copy it from [tests/env.example](tests/env.example)), which
is gitignored.

| Script | What it does |
|---|---|
| [tests/setup-conjur.sh](tests/setup-conjur.sh) | Creates a dedicated authn-jwt authenticator (static JWKS from the cluster), one host per test service account (bound by the `sub` claim), and test variables. Uses additive `conjur policy load` only, so it's safe on a shared tenant. |
| [tests/setup-cluster.sh](tests/setup-cluster.sh) | Installs the policies, generates the parameter ConfigMap (tenant TLS chain, authn-jwt URL, pinned image digests), and creates the labelled test namespace plus an unlabelled one. |
| [tests/run-tests.sh](tests/run-tests.sh) `[static\|e2e\|all]` | `static`: server-side dry-run of every case in [tests/cases/](tests/cases/), asserting on the mutated Pod. `e2e`: deploys [tests/e2e/](tests/e2e/) workloads that fetch real secrets. |
| [tests/teardown.sh](tests/teardown.sh) | Removes the test namespaces, policies and the Secrets Manager test resources. |

Last run: Kubernetes 1.36.5 (OrbStack), Secrets Manager SaaS, Secrets
Provider v1.11.1, authn-k8s-client v0.27.0. 62/62 mutation checks and 9/9
end-to-end checks passed:
- push-to-file native sidecar: secrets were present before the app started,
  and a rotated secret was refreshed within about 30s
- `k8s_secrets` init container: the Kubernetes Secret was populated, which
  depends on the injected service account token mount
- authenticator native sidecar: the access token was shared with the app

**Not yet covered:**
- Secretless end to end (mutation only)
- authn-k8s end to end
- coexistence with the webhook
- Job completion with native sidecars

## Roadmap

These are suggested next steps, not commitments; no owners are assigned yet.

- authn-jwt for Secretless
- Resource requests/limits and `runAsNonRoot` driven by the parameter ConfigMap
- Helm chart packaging
- Run `tests/run-tests.sh static` in CI against an ephemeral cluster
