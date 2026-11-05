#!/usr/bin/env bash
# Checks that the plugin never puts the Vault token on the docker command line.
#
# A token in docker's argv shows up in process listings (`ps`) on the agent and
# can end up in logs. The plugin should pass it as `--env VAULT_TOKEN` with no
# value, so docker copies it from its own environment instead.
#
# Uses a stub `docker` on PATH and a dummy token; it never talks to Vault or
# Docker. Needs bash and jq. Run: ./tests/token_not_in_docker_argv.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

dummy_token="dummy-token-not-a-real-secret-0123456789"
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# Stub docker: record every argument on its own line, record whether VAULT_TOKEN
# reached docker through the environment, and answer `vault kv get` with a fixed
# KV v2 payload.
mkdir -p "${work}/bin"
cat > "${work}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${STUB_ARGV_LOG}"
if [ "${1:-}" = "run" ]; then
  if [ "${VAULT_TOKEN:-}" = "${EXPECTED_TOKEN}" ]; then
    echo "env-token-present" >> "${STUB_ENV_LOG}"
  else
    echo "env-token-missing" >> "${STUB_ENV_LOG}"
  fi
  echo '{"data":{"data":{"foo":"stub-secret-value","with-dash":"stub-dash-value"}}}'
fi
exit 0
STUB
chmod +x "${work}/bin/docker"

run_hook() {
  # Runs the environment hook in a subshell, the way the agent sources it, and
  # prints the secrets it exported.
  local token_source="$1"
  (
    export PATH="${work}/bin:${PATH}"
    export STUB_ARGV_LOG="${work}/argv.log"
    export STUB_ENV_LOG="${work}/env.log"
    export EXPECTED_TOKEN="${dummy_token}"
    export BUILDKITE_JOB_ID="test-job"
    export VAULT_ADDR="http://vault.invalid:8200"
    export BUILDKITE_PLUGIN_VAULT_SECRETS_ENV_MY_SECRET="secret/test/foo"
    export BUILDKITE_PLUGIN_VAULT_SECRETS_ENV_MY_DASH_SECRET="secret/test/with-dash"
    unset VAULT_TOKEN BUILDKITE_PLUGIN_VAULT_SECRETS_TOKEN
    case "${token_source}" in
      plugin-option) export BUILDKITE_PLUGIN_VAULT_SECRETS_TOKEN="${dummy_token}" ;;
      environment) export VAULT_TOKEN="${dummy_token}" ;;
    esac
    # shellcheck disable=SC1091
    . "${repo_root}/hooks/environment" > /dev/null 2>&1
    echo "MY_SECRET=${MY_SECRET:-}"
    echo "MY_DASH_SECRET=${MY_DASH_SECRET:-}"
  )
}

for token_source in plugin-option environment; do
  : > "${work}/argv.log"
  : > "${work}/env.log"
  out="$(run_hook "${token_source}")"

  if grep -qF -- "${dummy_token}" "${work}/argv.log"; then
    fail "[${token_source}] the token value appears in docker's argv"
  fi
  if ! grep -qxF -- "VAULT_TOKEN" "${work}/argv.log"; then
    fail "[${token_source}] docker run is not given a bare 'VAULT_TOKEN' env name"
  fi
  if [ "$(grep -c . "${work}/env.log")" -ne 2 ] || grep -q missing "${work}/env.log"; then
    fail "[${token_source}] docker run did not get VAULT_TOKEN from its environment for every secret"
  fi
  if ! grep -qxF "MY_SECRET=stub-secret-value" <<< "${out}"; then
    fail "[${token_source}] MY_SECRET was not exported with the value from Vault"
  fi
  if ! grep -qxF "MY_DASH_SECRET=stub-dash-value" <<< "${out}"; then
    fail "[${token_source}] MY_DASH_SECRET was not exported with the value from Vault"
  fi
  if [ "${failures}" -eq 0 ]; then
    echo "ok: [${token_source}] token kept out of docker argv and secrets loaded"
  fi
done

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "all checks passed"
