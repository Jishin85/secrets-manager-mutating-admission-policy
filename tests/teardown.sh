#!/usr/bin/env bash
# Removes everything created by setup-cluster.sh and setup-conjur.sh.
# Only deletes the resources named in tests/env.
source "$(dirname "$0")/lib.sh"

log "Removing Kubernetes test resources"
kubectl delete namespace "$APP_NS" "$APP_NS-unlabelled" --ignore-not-found
kubectl delete -f "$REPO_DIR/policies/" --ignore-not-found
kubectl delete namespace secrets-manager --ignore-not-found

log "Removing Secrets Manager test resources"
conjur authenticator disable --id "authn-jwt/$AUTHN_ID" || true
render "$TESTS_DIR/conjur/delete-workloads.yml" > "$GEN_DIR/delete-workloads.yml"
render "$TESTS_DIR/conjur/delete-authn-jwt.yml" > "$GEN_DIR/delete-authn-jwt.yml"
conjur policy update -b data -f "$GEN_DIR/delete-workloads.yml"
conjur policy update -b conjur/authn-jwt -f "$GEN_DIR/delete-authn-jwt.yml"
