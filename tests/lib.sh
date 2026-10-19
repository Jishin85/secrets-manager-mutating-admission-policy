# Shared helpers for the test scripts. Source after `cd` into the repo root.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$TESTS_DIR")"
GEN_DIR="$TESTS_DIR/.generated"
# shellcheck source=/dev/null
source "$TESTS_DIR/env"
mkdir -p "$GEN_DIR"

render() {
  sed -e "s|{{AUTHN_ID}}|$AUTHN_ID|g" \
      -e "s|{{DATA_BRANCH}}|$DATA_BRANCH|g" \
      -e "s|{{APP_NS}}|$APP_NS|g" \
      -e "s|{{CONJUR_ACCOUNT}}|$CONJUR_ACCOUNT|g" \
      "$1"
}

log() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
