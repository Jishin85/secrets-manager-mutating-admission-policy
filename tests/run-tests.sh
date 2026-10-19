#!/usr/bin/env bash
# Exercises the admission policies.
#   static: server-side dry-run of each case in tests/cases, asserting on the
#           mutated Pod (admission policies run during --dry-run=server)
#   e2e:    real workloads that authenticate to Secrets Manager with authn-jwt
# Usage: tests/run-tests.sh [static|e2e|all]   (default: all)
source "$(dirname "$0")/lib.sh"

PASS=0
FAIL=0
FAILED=()
CASE=""
OUT='{}'
ERR=""

ok() { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
ko() { FAIL=$((FAIL + 1)); FAILED+=("$CASE: $1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }

kc() { kubectl "$@" 2> >(grep -v 'version difference' >&2); }

# mutate <case> [namespace]: dry-run create; sets OUT (Pod JSON) and ERR.
mutate() {
  CASE="$1"
  local ns="${2:-$APP_NS}"
  log "case: $CASE (namespace $ns)"
  if OUT="$(render "$TESTS_DIR/cases/$CASE.yaml" |
    kubectl create -n "$ns" --dry-run=server -o json -f - 2>"$GEN_DIR/err")"; then
    ERR=""
  else
    ERR="$(grep -v 'version difference' "$GEN_DIR/err" || true)"
    OUT='{}'
  fi
}

# Lookups return null (not empty) when nothing matches, so `== null` works.
JQ_DEFS='
  def ic(n): [.spec.initContainers[]? | select(.name == n)][0];
  def c(n): [.spec.containers[] | select(.name == n)][0];
  def vols: [.spec.volumes[]?.name];
  def vol(n): [.spec.volumes[]? | select(.name == n)][0];
  def env(ctr; n): [ctr.env[]? | select(.name == n)][0];
  def mounts(ctr): [ctr.volumeMounts[]?.mountPath];
  def ann: .metadata.annotations // {};
  def sa_path: "/var/run/secrets/kubernetes.io/serviceaccount";
'

# check <description> <jq boolean expression over the mutated Pod>
check() {
  local result
  result="$(jq -r --arg authn "$AUTHN_ID" "$JQ_DEFS $2" <<<"$OUT" 2>&1)"
  if [ "$result" = "true" ]; then ok "$1"; else ko "$1 [$result]"; fi
}

expect_admitted() {
  if [ -z "$ERR" ]; then ok "admitted"; else ko "admitted (got: $ERR)"; fi
}

expect_denied() {
  if [ -n "$ERR" ] && grep -qF -- "$1" <<<"$ERR"; then
    ok "denied: ${ERR#*: }"
  else
    ko "denied containing '$1' (got: ${ERR:-admitted})"
  fi
}

run_static() {
  CASE="install"
  log "server-side dry-run of all policy manifests"
  if kc apply --dry-run=server -f "$REPO_DIR/policies/" >/dev/null; then ok "policies accepted"; else ko "policies accepted"; fi

  mutate sp-sidecar
  expect_admitted
  check "Secrets Provider is the first init container" '.spec.initContainers[0].name == "cyberark-secrets-provider-for-k8s"'
  check "native sidecar (restartPolicy Always)" '.spec.initContainers[0].restartPolicy == "Always"'
  check "postStart waits for secrets" '.spec.initContainers[0].lifecycle.postStart.exec.command == ["/usr/local/bin/conjur-secrets-provided.sh"]'
  check "volumes podinfo, conjur-status, conjur-secrets, jwt-token" '(["podinfo","conjur-status","conjur-secrets","jwt-token"] - vols) == []'
  check "jwt-token audience and expiry" 'vol("jwt-token").projected.sources[0].serviceAccountToken | .audience == "conjur" and .expirationSeconds == 600'
  check "JWT_TOKEN_PATH set" 'env(.spec.initContainers[0]; "JWT_TOKEN_PATH").value == "/var/run/secrets/tokens/jwt"'
  check "CONJUR_AUTHN_URL targets the authn-jwt authenticator" 'env(.spec.initContainers[0]; "CONJUR_AUTHN_URL").value | endswith("/authn-jwt/" + $authn)'
  check "SA token mounted on Secrets Provider" 'mounts(.spec.initContainers[0]) | index(sa_path) != null'
  check "app receives /conjur/status and /conjur/secrets" '(["/conjur/status","/conjur/secrets"] - mounts(c("app"))) == []'
  check "status annotation injected" 'ann["conjur.org/status"] == "injected"'
  check "injector-only annotations removed" '[ann | has("conjur.org/inject", "conjur.org/inject-type", "conjur.org/conjur-inject-volumes")] | any | not'
  check "container-mode/secrets-destination normalised" 'ann["conjur.org/container-mode"] == "sidecar" and ann["conjur.org/secrets-destination"] == "file"'
  check "hardened securityContext" '.spec.initContainers[0].securityContext | .allowPrivilegeEscalation == false and .capabilities.drop == ["ALL"]'

  mutate sp-init
  expect_admitted
  check "custom-named Secrets Provider placed before existing init container" '[.spec.initContainers[].name] == ["sp", "setup"]'
  check "plain init container (no restartPolicy/lifecycle)" 'ic("sp") | has("restartPolicy") or has("lifecycle") | not'
  check "container-mode annotation stays init" 'ann["conjur.org/container-mode"] == "init"'

  mutate sp-k8s-secrets
  expect_admitted
  check "no conjur-secrets volume" 'vols | index("conjur-secrets") == null'
  check "app gets /conjur/status only" 'mounts(c("app")) | index("/conjur/status") != null and index("/conjur/secrets") == null'
  check "SA token mounted on Secrets Provider" 'mounts(.spec.initContainers[0]) | index(sa_path) != null'
  check "secrets-destination annotation k8s_secrets" 'ann["conjur.org/secrets-destination"] == "k8s_secrets"'

  mutate sp-existing-volume
  expect_admitted
  check "conjur-status volume not duplicated" '[.spec.volumes[] | select(.name == "conjur-status")] | length == 1'
  check "user-defined conjur-status volume kept as is" 'vol("conjur-status").emptyDir.medium == null'
  check "existing /conjur/status mount not duplicated" '[mounts(c("app"))[] | select(. == "/conjur/status")] | length == 1'
  check "second receiver (comma + space list) gets mounts" '(["/conjur/status","/conjur/secrets"] - mounts(c("sidecar-two"))) == []'

  mutate authn-sidecar
  expect_admitted
  check "authenticator is a native sidecar" 'ic("authenticator").restartPolicy == "Always"'
  check "CONJUR_AUTHN_LOGIN from authn-identity" 'env(ic("authenticator"); "CONJUR_AUTHN_LOGIN").value | endswith(":token-consumer")'
  check "CONTAINER_MODE sidecar" 'env(ic("authenticator"); "CONTAINER_MODE").value == "sidecar"'
  check "authn-jwt token volume and path" '(vols | index("jwt-token") != null) and env(ic("authenticator"); "JWT_TOKEN_PATH").value == "/var/run/secrets/tokens/jwt"'
  check "app gets read-only /run/conjur" 'first(c("app").volumeMounts[] | select(.mountPath == "/run/conjur")) | .readOnly == true'

  mutate authn-init-configmaps
  expect_admitted
  check "plain init container" 'ic("authenticator") | has("restartPolicy") | not'
  check "connection env from conjurConnConfig" 'env(ic("authenticator"); "CONJUR_ACCOUNT").valueFrom.configMapKeyRef.name == "conjur-connect"'
  check "login from conjurAuthConfig" 'env(ic("authenticator"); "CONJUR_AUTHN_LOGIN").valueFrom.configMapKeyRef.name == "conjur-auth"'
  check "no authn-jwt wiring when using ConfigMaps" 'env(ic("authenticator"); "JWT_TOKEN_PATH") == null and (vols | index("jwt-token") == null)'

  mutate secretless-configfile
  expect_admitted
  check "secretless native sidecar first" '.spec.initContainers[0].name == "secretless" and .spec.initContainers[0].restartPolicy == "Always"'
  check "configfile args" 'ic("secretless").args == ["-config-mgr", "configfile#/etc/secretless/secretless.yml"]'
  check "ConfigMap volume mounted at /etc/secretless" 'vol("secretless-config").configMap.name == "demo-secretless-config" and (mounts(ic("secretless")) | index("/etc/secretless") != null)'
  check "Secrets Manager env from cluster parameters" 'env(ic("secretless"); "CONJUR_APPLIANCE_URL").value != null and (env(ic("secretless"); "CONJUR_AUTHN_LOGIN").value | endswith(":demo-app"))'

  mutate secretless-legacy
  expect_admitted
  check "bare ConfigMap name treated as configfile" 'vol("secretless-config").configMap.name == "legacy-config" and ic("secretless").args[1] == "configfile#/etc/secretless/secretless.yml"'

  mutate secretless-crd
  expect_admitted
  check "k8s/crd passed through" 'ic("secretless").args == ["-config-mgr", "k8s/crd#my-secretless-crd"]'
  check "no secretless-config volume" 'vols | index("secretless-config") == null'
  check "SECRETLESS_CRD_SUFFIX set" 'env(ic("secretless"); "SECRETLESS_CRD_SUFFIX").value == "team-a"'

  mutate invalid-inject-type
  expect_denied 'invalid conjur.org/inject-type "foo"'

  mutate invalid-container-mode
  expect_denied 'conjur.org/container-mode value "bogus" not supported'

  mutate authn-no-identity
  expect_denied 'requires either conjur.org/conjurAuthConfig or conjur.org/authn-identity'

  mutate not-requested
  expect_admitted
  check "not mutated" '(.spec.initContainers == null) and (ann["conjur.org/status"] == null)'

  mutate already-injected
  expect_admitted
  check "not mutated again" '.spec.initContainers == null'

  mutate sp-sidecar "$APP_NS-unlabelled"
  expect_admitted
  check "unlabelled namespace: not mutated" '(.spec.initContainers == null) and ann["conjur.org/inject"] == "true"'

  # Parameter ConfigMap missing: injection requests fail closed, other pods
  # are unaffected.
  local backup="$GEN_DIR/params-backup.json"
  kc -n secrets-manager get configmap secrets-manager-sidecar-config -o json |
    jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.managedFields)' >"$backup"
  trap 'kubectl create -f "$backup" >/dev/null 2>&1 || true' EXIT
  kc -n secrets-manager delete configmap secrets-manager-sidecar-config >/dev/null
  mutate sp-sidecar
  CASE="missing-parameters: injection requested"
  expect_denied 'Secrets Manager sidecar injection was requested but not performed'
  mutate not-requested
  CASE="missing-parameters: no injection requested"
  expect_admitted
  kc create -f "$backup" >/dev/null
  trap - EXIT
}

# Prints diagnostics for a failed workload.
diag() {
  local app="$1"
  kc -n "$APP_NS" get pods -l "app=$app" -o wide || true
  kc -n "$APP_NS" describe pods -l "app=$app" | sed -n '/^Events:/,$p' | tail -15 || true
  for c in $(kubectl -n "$APP_NS" get pods -l "app=$app" -o jsonpath='{.items[0].spec.initContainers[*].name}' 2>/dev/null); do
    echo "--- logs: $c"
    kc -n "$APP_NS" logs "deploy/$app" -c "$c" --tail=30 || true
  done
}

# deploy <manifest> <deployment>: (re)creates the workload and waits for it.
deploy() {
  render "$TESTS_DIR/e2e/$1.yaml" | kc -n "$APP_NS" delete --ignore-not-found --wait=true -f - >/dev/null
  render "$TESTS_DIR/e2e/$1.yaml" | kc -n "$APP_NS" apply -f - >/dev/null
  if kc -n "$APP_NS" rollout status "deploy/$2" --timeout=240s >/dev/null; then
    ok "deployment $2 rolled out"
  else
    ko "deployment $2 rolled out"
    diag "$2"
    return 1
  fi
}

conjur_get() { conjur variable get -i "data/$DATA_BRANCH/$1"; }

run_e2e() {
  CASE="e2e-push-to-file"
  log "e2e: Secrets Provider native sidecar, push-to-file, authn-jwt"
  if deploy push-to-file demo-app; then
    local pw file at_start rotated i
    pw="$(conjur_get db/password)"
    file="$(kc -n "$APP_NS" exec deploy/demo-app -c app -- cat /conjur/secrets/db.yaml)"
    if grep -qF 'demo-user' <<<"$file" && grep -qF -- "$pw" <<<"$file"; then
      ok "secrets file contains values from Secrets Manager"
    else
      ko "secrets file contains values from Secrets Manager (got: $file)"
    fi
    at_start="$(kc -n "$APP_NS" exec deploy/demo-app -c app -- cat /tmp/at-start.yaml)"
    if grep -qF -- "$pw" <<<"$at_start"; then
      ok "secrets were present when the app container started"
    else
      ko "secrets were present when the app container started (got: $at_start)"
    fi

    rotated="rotated-$(openssl rand -hex 8)"
    conjur variable set -i "data/$DATA_BRANCH/db/password" -v "$rotated" >/dev/null
    for i in $(seq 1 24); do
      sleep 5
      if kc -n "$APP_NS" exec deploy/demo-app -c app -- cat /conjur/secrets/db.yaml | grep -qF -- "$rotated"; then
        break
      fi
    done
    if [ "$i" -lt 24 ]; then ok "rotated secret refreshed in file after ~$((i * 5))s"; else ko "rotated secret refreshed in file within 120s"; diag demo-app; fi
  fi

  CASE="e2e-k8s-secrets"
  log "e2e: Secrets Provider init container, k8s_secrets, authn-jwt"
  if deploy k8s-secrets k8s-secrets-app; then
    local user pass
    user="$(kc -n "$APP_NS" get secret db-credentials -o jsonpath='{.data.username}' | base64 -d)"
    pass="$(kc -n "$APP_NS" get secret db-credentials -o jsonpath='{.data.password}' | base64 -d)"
    if [ "$user" = "demo-user" ] && [ "$pass" = "$(conjur_get db/password)" ]; then
      ok "Kubernetes Secret populated from Secrets Manager"
    else
      ko "Kubernetes Secret populated from Secrets Manager (username='$user')"
    fi
    if kc -n "$APP_NS" logs deploy/k8s-secrets-app -c app | grep -qF 'username=demo-user'; then
      ok "app consumed the populated Secret"
    else
      ko "app consumed the populated Secret"
    fi
  fi

  CASE="e2e-authenticator"
  log "e2e: authenticator native sidecar, authn-jwt"
  if deploy authenticator token-consumer; then
    local token=""
    for i in $(seq 1 12); do
      token="$(kc -n "$APP_NS" exec deploy/token-consumer -c app -- cat /run/conjur/conjur-access-token 2>/dev/null || true)"
      [ -n "$token" ] && break
      sleep 5
    done
    if grep -qF '"payload"' <<<"$token"; then
      ok "access token shared with the app container"
    else
      ko "access token shared with the app container"
      diag token-consumer
    fi
  fi
}

mode="${1:-all}"
case "$mode" in
  static) run_static ;;
  e2e) run_e2e ;;
  all) run_static; run_e2e ;;
  *) echo "usage: $0 [static|e2e|all]" >&2; exit 2 ;;
esac

log "Summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
