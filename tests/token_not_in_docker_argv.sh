#!/usr/bin/env bash
# Checks that the plugin never exposes the Vault token or the AWS login request.
#
# A value in a command's argv shows up in process listings (`ps`) on the agent
# and can end up in logs. The plugin should:
# - pass the token to docker as `--env VAULT_TOKEN` with no value, so docker
#   copies it from its own environment;
# - run the vault container with `--rm`, so its config (which holds the token)
#   is gone as soon as it exits;
# - send the AWS-signed login request to curl on stdin (`--data @-`), so the
#   signed headers, which include the instance session token, never reach
#   curl's argv;
# - print neither the token nor the signed headers when the caller has
#   `set -x` on, and leave `set -x` as it found it.
#
# Uses stub `docker`, `curl`, `pip3` and `python3` on PATH and dummy values; it
# never talks to Vault, AWS or Docker. Needs bash and jq.
# Run: ./tests/token_not_in_docker_argv.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

dummy_token="dummy-token-not-a-real-secret-0123456789"
# Stands in for the signed STS headers, which carry the instance session token.
dummy_aws_headers="dummy-aws-signed-headers-not-a-real-secret-9876543210"
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# Stub docker: record every argument on its own line, record for each
# `docker run` whether it got the `--env VAULT_TOKEN` pair and `--rm`, and
# whether VAULT_TOKEN reached docker through the environment, and answer
# `vault kv get` with a fixed KV v2 payload.
mkdir -p "${work}/bin" "${work}/aws-bin"
cat > "${work}/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${STUB_ARGV_LOG}"
if [ "${1:-}" = "run" ]; then
  # Only docker's own options count, so scan up to the `--` before the image
  # and require that `--` to be there.
  pair="pair-missing"
  rm="rm-missing"
  saw_pair=""
  saw_rm=""
  prev=""
  for arg in "$@"; do
    if [ "${arg}" = "--" ]; then
      [ -n "${saw_pair}" ] && pair="pair-ok"
      [ -n "${saw_rm}" ] && rm="rm-ok"
      break
    fi
    if [ "${prev}" = "--env" ] && [ "${arg}" = "VAULT_TOKEN" ]; then
      saw_pair="yes"
    fi
    if [ "${arg}" = "--rm" ]; then
      saw_rm="yes"
    fi
    prev="${arg}"
  done
  echo "${pair}" >> "${STUB_RUN_LOG}"
  echo "${rm}" >> "${STUB_RUN_LOG}"
  if [ "${VAULT_TOKEN:-}" = "${EXPECTED_TOKEN}" ]; then
    echo "env-token-present" >> "${STUB_RUN_LOG}"
  else
    echo "env-token-missing" >> "${STUB_RUN_LOG}"
  fi
  echo '{"data":{"data":{"foo":"stub-secret-value","with-dash":"stub-dash-value"}}}'
fi
exit 0
STUB

# Stubs for the AWS auth path (only on PATH for that case): pip3 does nothing,
# the request signer returns the dummy headers, and curl records whether the
# login body came on stdin with those headers in it, then answers with the
# dummy token, as Vault would.
cat > "${work}/aws-bin/pip3" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat > "${work}/aws-bin/python3" <<'STUB'
#!/usr/bin/env bash
printf '{"iam_request_url":"dXJs","iam_request_body":"Ym9keQ==","iam_request_headers":"%s"}\n' "${EXPECTED_AWS_HEADERS}"
STUB
cat > "${work}/aws-bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${STUB_ARGV_LOG}"
stdin="stdin-missing"
prev=""
for arg in "$@"; do
  if [ "${prev}" = "--data" ] && [ "${arg}" = "@-" ]; then
    body="$(cat)"
    if [ "$(jq -r .iam_request_headers <<< "${body}")" = "${EXPECTED_AWS_HEADERS}" ]; then
      stdin="stdin-ok"
    fi
  fi
  prev="${arg}"
done
echo "${stdin}" >> "${STUB_CURL_LOG}"
printf '{"auth":{"client_token":"%s"}}\n' "${EXPECTED_TOKEN}"
STUB
chmod +x "${work}/bin/docker" "${work}/aws-bin/pip3" "${work}/aws-bin/python3" "${work}/aws-bin/curl"

run_hook() {
  # Runs the environment hook in a subshell, the way the agent sources it, and
  # prints the secrets it exported and whether `set -x` was on afterwards. With
  # trace=xtrace the hook runs under `set -x`; its trace goes to hook.log with
  # the rest of its output.
  local token_source="$1"
  local trace="$2"
  (
    # Start from a clean slate, in case the test runs inside a job that already
    # uses this plugin.
    for var in "${!BUILDKITE_PLUGIN_VAULT_SECRETS_@}"; do
      unset "${var}"
    done
    export PATH="${work}/bin:${PATH}"
    export STUB_ARGV_LOG="${work}/argv.log"
    export STUB_RUN_LOG="${work}/run.log"
    export STUB_CURL_LOG="${work}/curl.log"
    export EXPECTED_TOKEN="${dummy_token}"
    export EXPECTED_AWS_HEADERS="${dummy_aws_headers}"
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
    flags_after=""
    {
      if [ "${trace}" = "xtrace" ]; then
        set -x
      fi
      # shellcheck disable=SC1091
      . "${repo_root}/hooks/environment"
      flags_after="$-"
      set +x
    } > "${work}/hook.log" 2>&1
    echo "MY_SECRET=${MY_SECRET:-}"
    echo "MY_DASH_SECRET=${MY_DASH_SECRET:-}"
    case "${flags_after}" in
      *x*) echo "XTRACE_AFTER=on" ;;
      *) echo "XTRACE_AFTER=off" ;;
    esac
  )
}

for token_source in plugin-option environment aws-auth; do
  for trace in plain xtrace; do
    label="${token_source}, ${trace}"
    : > "${work}/argv.log"
    : > "${work}/run.log"
    : > "${work}/curl.log"
    failures_before="${failures}"
    # Not inside `if`: bash ignores `set -e` in a condition, even after the hook
    # turns it on, so a failing command in the hook would go unnoticed.
    set +e
    out="$(run_hook "${token_source}" "${trace}")"
    hook_status=$?
    set -e
    if [ "${hook_status}" -ne 0 ]; then
      fail "[${label}] the environment hook exited non-zero; last lines of its output:"
      tail -n 5 "${work}/hook.log"
      continue
    fi

    for value_name in dummy_token dummy_aws_headers; do
      value="${!value_name}"
      if grep -qF -- "${value}" "${work}/argv.log"; then
        fail "[${label}] ${value_name} appears in a command's argv"
      fi
      if grep -qF -- "${value}" "${work}/hook.log"; then
        fail "[${label}] ${value_name} appears in the hook's output"
      fi
    done
    # Two secrets, so two `docker run` calls, each needing all three records.
    if [ "$(grep -cx "pair-ok" "${work}/run.log")" -ne 2 ] || grep -qx "pair-missing" "${work}/run.log"; then
      fail "[${label}] not every docker run got a bare '--env VAULT_TOKEN'"
    fi
    if [ "$(grep -cx "rm-ok" "${work}/run.log")" -ne 2 ] || grep -qx "rm-missing" "${work}/run.log"; then
      fail "[${label}] not every docker run got '--rm'"
    fi
    if [ "$(grep -cx "env-token-present" "${work}/run.log")" -ne 2 ] || grep -qx "env-token-missing" "${work}/run.log"; then
      fail "[${label}] not every docker run got VAULT_TOKEN from its environment"
    fi
    if [ "${token_source}" = "aws-auth" ]; then
      if [ "$(grep -cx "stdin-ok" "${work}/curl.log")" -ne 1 ] || grep -qx "stdin-missing" "${work}/curl.log"; then
        fail "[${label}] the AWS login request did not reach curl on stdin via '--data @-'"
      fi
    fi
    if ! grep -qxF "MY_SECRET=stub-secret-value" <<< "${out}"; then
      fail "[${label}] MY_SECRET was not exported with the value from Vault"
    fi
    if ! grep -qxF "MY_DASH_SECRET=stub-dash-value" <<< "${out}"; then
      fail "[${label}] MY_DASH_SECRET was not exported with the value from Vault"
    fi
    if [ "${trace}" = "xtrace" ]; then
      expected_xtrace="on"
    else
      expected_xtrace="off"
    fi
    if ! grep -qxF "XTRACE_AFTER=${expected_xtrace}" <<< "${out}"; then
      fail "[${label}] the hook did not leave set -x ${expected_xtrace}"
    fi
    if [ "${failures}" -eq "${failures_before}" ]; then
      echo "ok: [${label}] token and AWS login kept out of argv and output, secrets loaded"
    fi
  done
done

if [ "${failures}" -ne 0 ]; then
  echo "${failures} check(s) failed"
  exit 1
fi
echo "all checks passed"
