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

# Stub docker: record every argument on its own line, record for each
# `docker run` whether it got the `--env VAULT_TOKEN` pair and whether
# VAULT_TOKEN reached docker through the environment, and answer `vault kv get`
# with a fixed KV v2 payload.
mkdir -p "${work}/bin" "${work}/aws-bin"
cat > "${work}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${STUB_ARGV_LOG}"
if [ "${1:-}" = "run" ]; then
  # Only docker's own options count, so scan up to the `--` before the image
  # and require that `--` to be there.
  pair="pair-missing"
  saw_pair=""
  prev=""
  for arg in "$@"; do
    if [ "${arg}" = "--" ]; then
      [ -n "${saw_pair}" ] && pair="pair-ok"
      break
    fi
    if [ "${prev}" = "--env" ] && [ "${arg}" = "VAULT_TOKEN" ]; then
      saw_pair="yes"
    fi
    prev="${arg}"
  done
  echo "${pair}" >> "${STUB_RUN_LOG}"
  if [ "${VAULT_TOKEN:-}" = "${EXPECTED_TOKEN}" ]; then
    echo "env-token-present" >> "${STUB_RUN_LOG}"
  else
    echo "env-token-missing" >> "${STUB_RUN_LOG}"
  fi
  echo '{"data":{"data":{"foo":"stub-secret-value","with-dash":"stub-dash-value"}}}'
fi
exit 0
STUB

# Stubs for the AWS auth path (only on PATH for that case): pip3 and the
# request signer do nothing useful, and curl answers the Vault login with the
# dummy token, as Vault would.
cat > "${work}/aws-bin/pip3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "${work}/aws-bin/python3" <<'STUB'
#!/usr/bin/env bash
echo '{"iam_request_url":"dXJs","iam_request_body":"Ym9keQ==","iam_request_headers":"e30="}'
STUB
cat > "${work}/aws-bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${STUB_ARGV_LOG}"
printf '{"auth":{"client_token":"%s"}}\n' "${EXPECTED_TOKEN}"
STUB
chmod +x "${work}/bin/docker" "${work}/aws-bin/pip3" "${work}/aws-bin/python3" "${work}/aws-bin/curl"

run_hook() {
  # Runs the environment hook in a subshell, the way the agent sources it, and
  # prints the secrets it exported.
  local token_source="$1"
  (
    # Start from a clean slate, in case the test runs inside a job that already
    # uses this plugin.
    for var in "${!BUILDKITE_PLUGIN_VAULT_SECRETS_@}"; do
      unset "${var}"
    done
    export PATH="${work}/bin:${PATH}"
    export STUB_ARGV_LOG="${work}/argv.log"
    export STUB_RUN_LOG="${work}/run.log"
    export EXPECTED_TOKEN="${dummy_token}"
    export BUILDKITE_JOB_ID="test-job"
    export VAULT_ADDR="http://vault.invalid:8200"
    export BUILDKITE_PLUGIN_VAULT_SECRETS_ENV_MY_SECRET="secret/test/foo"
    export BUILDKITE_PLUGIN_VAULT_SECRETS_ENV_MY_DASH_SECRET="secret/test/with-dash"
    unset VAULT_TOKEN
    case "${token_source}" in
      plugin-option) export BUILDKITE_PLUGIN_VAULT_SECRETS_TOKEN="${dummy_token}" ;;
      environment) export VAULT_TOKEN="${dummy_token}" ;;
      aws-auth) export PATH="${work}/aws-bin:${PATH}" ;;
    esac
    # shellcheck disable=SC1091
    . "${repo_root}/hooks/environment" > "${work}/hook.log" 2>&1
    echo "MY_SECRET=${MY_SECRET:-}"
    echo "MY_DASH_SECRET=${MY_DASH_SECRET:-}"
  )
}

for token_source in plugin-option environment aws-auth; do
  : > "${work}/argv.log"
  : > "${work}/run.log"
  failures_before="${failures}"
  # Not inside `if`: bash ignores `set -e` in a condition, even after the hook
  # turns it on, so a failing command in the hook would go unnoticed.
  set +e
  out="$(run_hook "${token_source}")"
  hook_status=$?
  set -e
  if [ "${hook_status}" -ne 0 ]; then
    fail "[${token_source}] the environment hook exited non-zero; last lines of its output:"
    tail -n 5 "${work}/hook.log"
    continue
  fi

  if grep -qF -- "${dummy_token}" "${work}/argv.log"; then
    fail "[${token_source}] the token value appears in a command's argv"
  fi
  if grep -qF -- "${dummy_token}" "${work}/hook.log"; then
    fail "[${token_source}] the token value appears in the hook's output"
  fi
  # Two secrets, so two `docker run` calls, each needing both records.
  if [ "$(grep -cx "pair-ok" "${work}/run.log")" -ne 2 ] || grep -qx "pair-missing" "${work}/run.log"; then
    fail "[${token_source}] not every docker run got a bare '--env VAULT_TOKEN'"
  fi
  if [ "$(grep -cx "env-token-present" "${work}/run.log")" -ne 2 ] || grep -qx "env-token-missing" "${work}/run.log"; then
    fail "[${token_source}] not every docker run got VAULT_TOKEN from its environment"
  fi
  if ! grep -qxF "MY_SECRET=stub-secret-value" <<< "${out}"; then
    fail "[${token_source}] MY_SECRET was not exported with the value from Vault"
  fi
  if ! grep -qxF "MY_DASH_SECRET=stub-dash-value" <<< "${out}"; then
    fail "[${token_source}] MY_DASH_SECRET was not exported with the value from Vault"
  fi
  if [ "${failures}" -eq "${failures_before}" ]; then
    echo "ok: [${token_source}] token kept out of docker argv and secrets loaded"
  fi
done

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "all checks passed"
