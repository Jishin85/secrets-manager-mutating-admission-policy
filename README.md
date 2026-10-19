# Secrets Manager Sidecar Injection: MutatingAdmissionPolicy

A community project providing Kubernetes-native sidecar injection for Palo
Alto Networks Idira Secrets Manager (formerly CyberArk Conjur). It is an
alternative to the
[cyberark/sidecar-injector](https://github.com/cyberark/sidecar-injector)
mutating webhook, built from `MutatingAdmissionPolicy` resources that run as
CEL inside kube-apiserver. There is no server to deploy, no TLS certificate or
CSR to manage, and no network hop on pod creation.

The pod annotation contract (`conjur.org/*`) and the namespace opt-in label
(`cyberark-sidecar-injector=enabled`) are the same as the webhook's, so
existing workloads can move over without manifest changes.

> [!IMPORTANT]
> **Disclaimer: community effort, not an official repository.**
> This project is not developed, endorsed, or supported by Palo Alto Networks
> or CyberArk. It is not a product, and its contents are not an official
> recommendation or roadmap. It is provided "as is", without warranty of any
> kind. Palo Alto Networks and CyberArk support does not cover it; raise
> questions as issues in this repository.
>
> Validate it in your own environment before relying on it. For supported
> deployment options, see the official Secrets Manager documentation.
>
> Palo Alto Networks, Idira, CyberArk, Conjur and related names are
> trademarks of their respective owners. They are used here only to identify
> the products this project works with.

**Status:** tested on Kubernetes 1.36 against Secrets Manager SaaS.
- Secrets Provider (push-to-file and `k8s_secrets`) and the authenticator
  client were verified end to end with authn-jwt.
- Secretless and the authn-k8s path are covered by mutation tests only.

See [Testing](#testing) for details and the gaps that remain.

## Contents

```
config/sidecar-config.yaml         Namespace + parameter ConfigMap (images, Secrets Manager connection)
policies/secrets-provider.yaml     MutatingAdmissionPolicy + Binding: inject-type secrets-provider
policies/authenticator.yaml        MutatingAdmissionPolicy + Binding: inject-type authenticator
policies/secretless.yaml           MutatingAdmissionPolicy + Binding: inject-type secretless
policies/validation.yaml           ValidatingAdmissionPolicy + Binding: rejects invalid/uninjected pods
examples/                          Annotated sample workloads
docs/sidecar-injector-analysis.md  Study of the webhook and the problems this design addresses
tests/                             Secrets Manager setup, mutation tests and end-to-end tests
kustomization.yaml
LICENSE, NOTICE                    Apache License 2.0 and attribution
```

## Requirements

- **Kubernetes 1.36 or later.** The policies use
  `admissionregistration.k8s.io/v1`, where `MutatingAdmissionPolicy` is GA.
  On 1.34/1.35, change the policy and binding `apiVersion` to `v1beta1` (the
  spec fields are the same) and enable the beta API on kube-apiserver with:
  - `--feature-gates=MutatingAdmissionPolicy=true`
  - `--runtime-config=admissionregistration.k8s.io/v1beta1=true`

  On managed Kubernetes and OpenShift, check that your platform version
  serves the API. Then check whether it lets you enable beta APIs.
- **Native sidecar containers** (`initContainers[].restartPolicy: Always`),
  which are GA since 1.33. Every cluster that supports the policies has them.
- **Network access** from the nodes to the Secrets Manager endpoint (SaaS
  tenant, Follower, or server).
- **Images:** the upstream Secrets Provider and authenticator images were
  amd64-only at the time of testing. Nodes on other architectures need
  emulation, or images built for their architecture.

## Install

1. Edit `config/sidecar-config.yaml`:
   - Pin the images, preferably by digest.
   - Set the Secrets Manager account, appliance URL and CA certificate.
   - Set either the authn-k8s authenticator ID or an authn-jwt
     `CONJUR_AUTHN_URL` (see [Authentication](#authentication-authn-k8s-or-authn-jwt)).

   If you already have a Golden ConfigMap from the cluster-prep Helm chart,
   you can point `paramRef` in each binding at it instead, because the key
   names match.
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

  This is the recommended option for **Secrets Manager SaaS**, which usually
  cannot reach a private cluster's API server.

When the cluster's JWKS endpoint isn't reachable from Secrets Manager,
configure the authenticator with static `public-keys` (see
[tests/setup-conjur.sh](tests/setup-conjur.sh)). Those keys must then be
updated whenever the cluster rotates its service account signing keys.

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
sidecar reads the same configuration the policy acted on. Secrets Provider
logs `conjur.org/status` as "valid, but not recognized"; this is harmless.

## Differences from the webhook

This project deliberately behaves differently from the webhook in these ways:

- **Native sidecars.** "Sidecar" mode injects an init container with
  `restartPolicy: Always`, inserted first in `initContainers`. As a result:
  - The sidecar starts before the application and stops after it.
  - Jobs can complete. This follows from native sidecar semantics; this
    project hasn't tested it yet.
  - For Secrets Provider, a `postStart` hook
    (`/usr/local/bin/conjur-secrets-provided.sh`) holds back the application
    containers until secrets are present. This addresses the ordering problem
    noted in the webhook's GA design doc.
- **Defaults for missing annotations.** Secrets Provider gets a default
  container name. `conjur-secrets` mounts are not added in `k8s_secrets`
  mode. Volumes that already exist are reused instead of duplicated.
- **Service account token.** Secrets Provider and Secretless get the pod's
  service account token mounted. This is needed because the ServiceAccount
  admission plugin runs before admission policies. Testing confirmed the
  token is otherwise missing from injected containers.
- **No per-namespace ConfigMaps needed** for the authenticator and Secretless.
  They fall back to the cluster parameter ConfigMap. Referencing namespace
  ConfigMaps still works as before.
- **Hardened containers.** Injected containers get
  `allowPrivilegeEscalation: false`, drop all capabilities and use the
  `RuntimeDefault` seccomp profile. The default `imagePullPolicy` is
  `IfNotPresent` (configurable).
- **Fail-closed validation that doesn't block other pods.** If a pod requests
  injection but is not mutated, `ValidatingAdmissionPolicy` rejects it with a
  reason. Causes include invalid annotations, a missing binding, a missing
  parameter ConfigMap, or the API being disabled.

  The bindings use `parameterNotFoundAction: Allow`. Kubernetes resolves
  parameters before `matchConditions`, so `Deny` would block every pod in a
  labelled namespace whenever the parameter ConfigMap was missing.
- **authn-jwt support** (see [Authentication](#authentication-authn-k8s-or-authn-jwt)).
- **Legacy (non-native) sidecar placement in `containers` is not offered.**

## Migrating from the webhook

The webhook and the policies are designed to run side by side during a
cutover. Admission policies run before admission webhooks. After a policy
injects a pod, it sets `conjur.org/status: injected` and removes
`conjur.org/inject`, and the webhook skips pods in that state. This
coexistence has **not been tested yet**, so try it on a non-production
cluster first.

1. Install this project (see [Install](#install)).
2. Roll a test workload in a labelled namespace. Confirm the pod has the
   injected init container and `conjur.org/status: injected`.
3. Uninstall the webhook: `helm uninstall <release> -n injectors`. Then delete
   its CSR (`kubectl delete csr cyberark-sidecar-injector.injectors`) and its
   namespace.

## Testing

[tests/](tests/) contains a complete, re-runnable test setup. It works with
any Kubernetes 1.36+ cluster that `kubectl` points at, plus the Secrets
Manager CLI (`conjur`), `jq` and `openssl`. All names come from `tests/env`
(copy it from [tests/env.example](tests/env.example)), which is gitignored.

| Script | What it does |
|---|---|
| [tests/setup-conjur.sh](tests/setup-conjur.sh) | Creates a dedicated authn-jwt authenticator (static JWKS read from the cluster), one host per test service account (bound by the `sub` claim), and test variables. Uses additive `conjur policy load` only, so it's safe on a shared tenant. |
| [tests/setup-cluster.sh](tests/setup-cluster.sh) | Installs the policies, generates the parameter ConfigMap (tenant TLS chain, authn-jwt URL, pinned image digests), and creates the labelled test namespace plus an unlabelled one. |
| [tests/run-tests.sh](tests/run-tests.sh) `[static\|e2e\|all]` | `static`: server-side dry-run of every case in [tests/cases/](tests/cases/), asserting on the mutated Pod. `e2e`: deploys [tests/e2e/](tests/e2e/) workloads that fetch real secrets. |
| [tests/teardown.sh](tests/teardown.sh) | Removes the test namespaces, policies and the Secrets Manager test resources. |

**Last run:** a single-node Kubernetes 1.36.5 cluster, Secrets Manager SaaS,
Secrets Provider v1.11.1 and authn-k8s-client v0.27.0. 62/62 mutation checks
and 9/9 end-to-end checks passed:
- push-to-file native sidecar: secrets were present before the app started,
  and a rotated secret was refreshed within about 30s
- `k8s_secrets` init container: the Kubernetes Secret was populated, which
  depends on the injected service account token mount
- authenticator native sidecar: the access token was shared with the app

**Not yet covered:**
- Secretless end to end (mutation only)
- authn-k8s end to end (needs a Secrets Manager instance that can reach the
  cluster)
- coexistence with the webhook
- Job completion with native sidecars
- managed platforms (EKS, AKS, GKE) and OpenShift

## Roadmap

These are suggested next steps for contributors. They are not commitments and
not an official product roadmap; no owners are assigned.

**Test coverage**
- Fill the gaps listed above, starting with webhook coexistence and Job
  completion, since migration depends on them.
- Run `tests/run-tests.sh static` in CI against an ephemeral cluster.
- Test on managed Kubernetes and OpenShift. On OpenShift, SCCs may interact
  with the injected `securityContext`.

**Policy features**
- authn-jwt for Secretless.
- A startup probe for the authenticator sidecar, so applications don't start
  before the first access token is written. Today they have to wait for the
  file themselves.
- Resource requests/limits from the parameter ConfigMap.
- `runAsNonRoot: true` by default. Both tested images already run as non-root
  users (`secrets-provider`, `authenticator`).
- Validation that every name in `conjur.org/conjur-inject-volumes` matches a
  container. Unknown names are currently ignored silently, as in the webhook.

**Operations**
- Guidance or automation for keeping a static authn-jwt `public-keys`
  variable in sync with the cluster's service account signing keys.
- Helm chart packaging.

**Upstream requests**
- Multi-architecture (arm64) images for Secrets Provider and the
  authenticator client.

## License

Licensed under the [Apache License, Version 2.0](LICENSE), the same license
as the upstream
[cyberark/sidecar-injector](https://github.com/cyberark/sidecar-injector).
This project's annotation contract and injection behaviour are based on that
project; see [NOTICE](NOTICE) for attribution.

The license's "AS IS" terms add to the disclaimer at the top of this README.
They don't replace it: this remains an unofficial community project.
