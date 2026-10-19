#!/usr/bin/env bash
# Creates the dedicated authn-jwt authenticator, test hosts and test secrets in
# Secrets Manager. Uses additive `policy load` only, so it is safe on a shared
# tenant and can be re-run.
source "$(dirname "$0")/lib.sh"

for f in authn-jwt workloads grants; do
  render "$TESTS_DIR/conjur/$f.yml" > "$GEN_DIR/$f.yml"
done

log "Loading authenticator conjur/authn-jwt/$AUTHN_ID"
conjur policy load -b conjur/authn-jwt -f "$GEN_DIR/authn-jwt.yml"
log "Loading workloads data/$DATA_BRANCH"
conjur policy load -b data -f "$GEN_DIR/workloads.yml"
log "Granting workloads access to the authenticator"
conjur policy load -b "conjur/authn-jwt/$AUTHN_ID" -f "$GEN_DIR/grants.yml"

log "Configuring authenticator from the cluster's service account issuer"
jwks="$(kubectl get --raw /openid/v1/jwks 2>/dev/null)"
issuer="$(kubectl get --raw /.well-known/openid-configuration 2>/dev/null |
  python3 -I -c 'import json,sys; print(json.load(sys.stdin)["issuer"])')"
conjur variable set -i "conjur/authn-jwt/$AUTHN_ID/public-keys" -v "{\"type\":\"jwks\",\"value\":$jwks}"
conjur variable set -i "conjur/authn-jwt/$AUTHN_ID/issuer" -v "$issuer"
conjur variable set -i "conjur/authn-jwt/$AUTHN_ID/audience" -v "$JWT_AUDIENCE"

log "Setting test secret values"
conjur variable set -i "data/$DATA_BRANCH/db/url" -v "postgresql://db.example.internal:5432/demo"
conjur variable set -i "data/$DATA_BRANCH/db/username" -v "demo-user"
conjur variable set -i "data/$DATA_BRANCH/db/password" -v "initial-$(openssl rand -hex 8)"

log "Enabling authn-jwt/$AUTHN_ID"
conjur authenticator enable --id "authn-jwt/$AUTHN_ID"
