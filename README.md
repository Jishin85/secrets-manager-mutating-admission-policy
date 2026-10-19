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

> **Status: draft, not yet validated.** These manifests were written from
> the webhook source and the Kubernetes API reference, and have not yet been
> applied to a cluster. Complete the [validation checklist](#validation-checklist)
> before you adopt them.

## Contents

```
config/sidecar-config.yaml       Namespace + parameter ConfigMap (images, Secrets Manager connection)
policies/secrets-provider.yaml   MutatingAdmissionPolicy + Binding: inject-type secrets-provider
policies/authenticator.yaml      MutatingAdmissionPolicy + Binding: inject-type authenticator
policies/secretless.yaml         MutatingAdmissionPolicy + Binding: inject-type secretless
policies/validation.yaml         ValidatingAdmissionPolicy + Binding: rejects invalid/uninjected pods
examples/                        Annotated sample workloads
docs/sidecar-injector-analysis.md  Study of the webhook and the problems this design fixes
kustomization.yaml
```

## Requirements

- **Kubernetes 1.34 or later.** The policies use
  `admissionregistration.k8s.io/v1beta1`. On 1.34/1.35 the beta API is off by
  default. Enable it on kube-apiserver with:
  - `--feature-gates=MutatingAdmissionPolicy=true`
  - `--runtime-config=admissionregistration.k8s.io/v1beta1=true`

  If your cluster serves `MutatingAdmissionPolicy` at
  `admissionregistration.k8s.io/v1`, change the `apiVersion` of the policies
  and bindings to `v1`. The spec fields are the same. On managed Kubernetes,
  check whether the provider lets you enable the API.
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
- **Fail-closed validation.** If a pod requests injection but is not mutated,
  `ValidatingAdmissionPolicy` rejects it with a reason. Causes include invalid
  annotations, a missing binding, a missing parameter ConfigMap, or the API
  being disabled. Previously such pods could start without secrets.
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

## Validation checklist

Before production, verify the following on a non-production cluster:

- [ ] `kubectl apply --dry-run=server -k .` accepts all objects. This
      type-checks every CEL expression against the Pod schema.
- [ ] The CEL features used compile on your Kubernetes version:
      optional types (`[?key]`, `.orValue()`, `?field:`),
      `jsonpatch.escapeKey`, typed `Object.spec...{}` construction, and
      `list.indexOf`.
- [ ] Each example in [examples/](examples/) is mutated as documented
      (`kubectl get pod -o yaml`), for both `init` and `sidecar` modes.
- [ ] The Secrets Provider image contains `/usr/local/bin/conjur-secrets-provided.sh`,
      and the app containers start only after secrets are written.
- [ ] The injected `securityContext` works with each pinned image.
- [ ] Invalid annotations (for example `conjur.org/inject-type: foo`) are
      rejected with the validation message.
- [ ] Deleting the parameter ConfigMap causes annotated pods to be denied
      rather than started without a sidecar.

## Roadmap

- authn-jwt support for Secrets Provider (projected service account token
  volume plus `JWT_TOKEN_PATH`)
- Resource requests/limits and `runAsNonRoot` driven by the parameter ConfigMap
- Helm chart packaging
- Automated tests (server-side dry-run against an API server in CI)
