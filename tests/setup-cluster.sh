#!/usr/bin/env bash
# Installs the admission policies, generates the parameter ConfigMap for the
# test tenant (authn-jwt), and prepares the test namespaces. Re-runnable.
source "$(dirname "$0")/lib.sh"

# Pinned by digest: Secrets Provider v1.11.1, authn-k8s-client v0.27.0
# (amd64-only images at the time of testing; other node architectures need emulation).
SECRETS_PROVIDER_IMAGE="${SECRETS_PROVIDER_IMAGE:-cyberark/secrets-provider-for-k8s@sha256:7fd400223ca22b192016771ebb58395faa8b7f4e40780c3ef1259af7b8eb92d6}"
AUTHENTICATOR_IMAGE="${AUTHENTICATOR_IMAGE:-cyberark/conjur-authn-k8s-client@sha256:948966533bb43c75bdc46aacf1541f764bd83d91e119b68af1c944256c32a3f4}"

host="$(printf '%s' "$CONJUR_URL" | sed -E 's#^https://([^/]+).*#\1#')"
log "Fetching TLS certificate chain for $host"
# LibreSSL on macOS exits non-zero ("poll error") after printing the chain.
{ openssl s_client -showcerts -connect "$host:443" -servername "$host" </dev/null 2>/dev/null || true; } |
  awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' > "$GEN_DIR/conjur-chain.pem"
count="$(grep -c 'BEGIN CERTIFICATE' "$GEN_DIR/conjur-chain.pem" || true)"
[ "$count" -gt 0 ] || { echo "no certificates retrieved from $host" >&2; exit 1; }
echo "$count certificates"

log "Applying admission policies"
kubectl apply -f "$REPO_DIR/policies/"

log "Creating parameter ConfigMap secrets-manager/secrets-manager-sidecar-config"
kubectl create namespace secrets-manager --dry-run=client -o yaml | kubectl apply -f -
kubectl -n secrets-manager create configmap secrets-manager-sidecar-config \
  --from-literal=secretsProviderImage="$SECRETS_PROVIDER_IMAGE" \
  --from-literal=authenticatorImage="$AUTHENTICATOR_IMAGE" \
  --from-literal=imagePullPolicy=IfNotPresent \
  --from-literal=conjurAccount="$CONJUR_ACCOUNT" \
  --from-literal=conjurApplianceUrl="$CONJUR_URL" \
  --from-literal=CONJUR_AUTHN_URL="$CONJUR_URL/authn-jwt/$AUTHN_ID" \
  --from-literal=jwtAudience="$JWT_AUDIENCE" \
  --from-file=conjurSslCertificate="$GEN_DIR/conjur-chain.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

log "Preparing namespaces $APP_NS (labelled) and $APP_NS-unlabelled"
kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$APP_NS" cyberark-sidecar-injector=enabled --overwrite
kubectl create namespace "$APP_NS-unlabelled" --dry-run=client -o yaml | kubectl apply -f -
for sa in demo-app k8s-secrets-app token-consumer; do
  kubectl -n "$APP_NS" create serviceaccount "$sa" --dry-run=client -o yaml | kubectl apply -f -
done
kubectl -n "$APP_NS-unlabelled" create serviceaccount demo-app --dry-run=client -o yaml | kubectl apply -f -

log "Policy type-checking status"
kubectl get mutatingadmissionpolicies,validatingadmissionpolicies \
  -o custom-columns='NAME:.metadata.name,TYPECHECK:.status.typeChecking'
