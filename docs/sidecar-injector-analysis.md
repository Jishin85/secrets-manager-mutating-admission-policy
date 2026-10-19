# Analysis: cyberark/sidecar-injector

Source studied: <https://github.com/cyberark/sidecar-injector> at commit
`b0d219e` (v1.0.2, 2025-12-10).

## How it works

A Go HTTPS server (`cmd/sidecar-injector`, `pkg/inject`) is registered as a
`MutatingWebhookConfiguration` for `CREATE pods` in namespaces labelled
`cyberark-sidecar-injector=enabled`. For each request, `HandleAdmissionRequest`:

1. Skips `kube-system` / `kube-public`, and pods whose `conjur.org/status` is
   already `injected`.
2. Requires `conjur.org/inject` to be one of `y|yes|true|on`.
3. Switches on `conjur.org/inject-type` and builds a `PatchConfig`
   (init containers, containers, volumes, and per-container volume mounts).
4. Generates an RFC 6902 JSON patch (`patch.go`) that appends containers and
   volumes, adds mounts to the containers listed in
   `conjur.org/conjur-inject-volumes`, and rewrites the annotation map: it sets
   `conjur.org/status=injected` and removes the injector-only annotations.

Images come from CLI flags (`-secrets-provider-image`, ...) and can be
overridden per pod with `conjur.org/container-image`. Secrets Provider
connection values come from the injector's own environment, loaded from the
"Golden ConfigMap" with `envFrom`.

### Per sidecar type

| Type | Placement | Volumes | Env source | Notes |
|---|---|---|---|---|
| `secrets-provider` | `containers` (appended), or `initContainers` if mode `init` | `podinfo` (downward API annotations), `conjur-status`, `conjur-secrets` (file mode only) | Literals from the injector's env (Golden ConfigMap) | `CONJUR_AUTHN_URL` defaults to `<applianceUrl>/authn-k8s/<authenticatorId>` |
| `authenticator` | `containers` (appended), or `initContainers` if mode `init` | `conjur-access-token` | `configMapKeyRef` into the namespace ConfigMaps named by `conjurConnConfig` / `conjurAuthConfig` (both required) | Container name defaults to `authenticator` |
| `secretless` | `containers` (appended), sidecar only | `secretless-config` (ConfigMap, configfile mode) | Field refs, plus `configMapKeyRef` if either Conjur ConfigMap annotation is set | Mounts the SA token volume itself; rejects pods without one |

## Problems found

Operational:

- **TLS lifecycle.** The webhook needs a serving certificate. The Helm chart
  generates a CSR using the `kubernetes.io/kubelet-serving` signer with a
  `system:node:` CN workaround, and a human must approve it
  (`kubectl certificate approve`). There is no rotation.
- **Availability.** The chart defaults to 1 replica, and the
  `MutatingWebhookConfiguration` leaves `failurePolicy` unset, which means
  `Fail` in `admissionregistration/v1`. If the injector pod is down, no pod can
  be created in any labelled namespace.
- **Extra component to run.** The webhook needs a Deployment, Service,
  ServiceAccount, RBAC, image supply chain and CVE patching (most changelog
  entries are dependency bumps), plus a network hop and serialisation on every
  pod CREATE in labelled namespaces.

Functional (from reading the code):

- **Secrets Provider has no default container name.** `containerName` comes
  straight from `conjur.org/container-name`. Without that annotation the
  injected container has `name: ""`, which fails API validation.
- **k8s_secrets mode builds an invalid pod.** The `conjur-secrets` volume is
  only created in `file` mode, but `conjur-secrets` mounts are added to
  receiver containers in every mode.
- **Injected containers don't get the service account token.** The built-in
  ServiceAccount admission plugin runs before webhooks, so it never sees the
  injected container. Only the Secretless path works around this. Secrets
  Provider in `k8s_secrets` mode needs API access.
- **Startup ordering is unsolved.** The design doc
  (`design/sidecar-injector-ga-design.md`) notes that Secrets Provider's
  `postStart` synchronisation needs the container to be listed first, but
  `addContainer` always appends.
- **Legacy sidecars block Jobs.** Regular sidecar containers keep running
  after the main container exits, so Jobs never complete.
- **Partial ConfigMap config (Secretless).** If only one of
  `conjurConnConfig` / `conjurAuthConfig` is set, the other variables get a
  `configMapKeyRef` with an empty name, which makes the pod invalid.
- **Name collisions.** Volumes are appended without checking for an existing
  volume of the same name, which also makes the pod invalid.
- **Defaults.** Images default to `:latest` and `imagePullPolicy: Always` is
  hard-coded. The authenticator receives `CONTAINER_MODE=""` when the
  annotation is absent.

## How the MutatingAdmissionPolicy addresses these

| Webhook concern | Policy approach |
|---|---|
| Server, TLS, CSR approval, HA | None: CEL runs inside kube-apiserver |
| Image/connection config via flags + `envFrom` | Parameter ConfigMap (`paramKind: ConfigMap`) using Golden ConfigMap key names |
| Error responses for bad annotations | Companion `ValidatingAdmissionPolicy` with the same messages, plus a fail-closed check when injection was requested but not performed |
| Container ordering / startup sync | Sidecar is inserted at index 0 of `initContainers` as a native sidecar (`restartPolicy: Always`). Secrets Provider gets a `postStart` hook, so the kubelet holds application containers until secrets are present |
| Jobs never complete | Native sidecars are stopped after the main containers exit |
| Missing SA token mount | Secrets Provider and Secretless mount the pod's SA token volume when one exists |
| Empty SP container name | Defaults to `cyberark-secrets-provider-for-k8s` |
| k8s_secrets invalid mounts | `conjur-secrets` is only mounted and created in file mode |
| Volume name collisions | Existing volumes/mounts with the same name or path are reused, not duplicated |
| Per-namespace ConfigMaps required (authenticator) | Optional: falls back to cluster parameters + `conjur.org/authn-identity` |
