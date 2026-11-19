#!/usr/bin/env bash

# SIGN_REQUEST_FILE_URL="https://raw.githubusercontent.com/hashicorp/terraform-aws-vault/master/examples/vault-consul-ami/auth/sign-request.py"
SIGN_REQUEST_FILE_PATH="$basedir/lib/sign-request.py"
# function download_request_signer_script() {
#   if [ ! -f "${SIGN_REQUEST_FILE_PATH}" ]; then
#     echo "--- downloading sign_requests.py from ${SIGN_REQUEST_FILE_URL}"
#     curl -sL -o $SIGN_REQUEST_FILE_PATH $SIGN_REQUEST_FILE_URL
#   fi
# }

function vault_auth_aws() {
  # parse auth data
  # download_request_signer_script
  auth_url="${VAULT_ADDR}/v1/auth"
  if [ -n "${BUILDKITE_PLUGIN_VAULT_SECRETS_AUTH_PATH:-"aws"}" ]; then
    auth_url="${auth_url}/${BUILDKITE_PLUGIN_VAULT_SECRETS_AUTH_PATH:-"aws"}/login"
  fi
  if [ -n "${BUILDKITE_PLUGIN_VAULT_SECRETS_AUTH_HEADER:-${VAULT_ADDR}}" ]; then
    VAULT_IAM_SERVER_HEADER=$(echo ${BUILDKITE_PLUGIN_VAULT_SECRETS_AUTH_HEADER:-${VAULT_ADDR}} | sed 's/.*:\/\///' | sed 's/:.*//' | sed 's/\/.*//')
  fi
  # Agents on one host share $HOME, so they share pip's user site-packages
  # (~/.local). Two jobs installing into it at once delete each other's files
  # mid-copy, so take a host-wide lock: one job installs and the rest find
  # boto3 already there and write nothing. Install unlocked when flock is
  # missing or the lock file can't be opened: the hook runs under set -e, so a
  # failed flock would stop the job, while an unlocked install only risks the
  # race. flock opens the file read-only and creates it if missing, so the
  # check does the same: create it if missing, then require read access.
  local pip_lock="${HOME:-}/.vault-secrets-buildkite-plugin-pip.lock"
  if [ -n "${HOME:-}" ] && command -v flock > /dev/null 2>&1 \
    && { [ -e "${pip_lock}" ] || touch "${pip_lock}"; } 2> /dev/null \
    && [ -r "${pip_lock}" ]; then
    flock "${pip_lock}" pip3 install boto3==1.33.12
  else
    pip3 install boto3==1.33.12
  fi
  signed_request=$(python3 ${SIGN_REQUEST_FILE_PATH} ${VAULT_IAM_SERVER_HEADER})
  iam_request_url=$(echo $signed_request | jq -r .iam_request_url)
  iam_request_body=$(echo $signed_request | jq -r .iam_request_body)
  iam_request_headers=$(echo $signed_request | jq -r .iam_request_headers)
  data=$(cat <<EOF
{
  "role":"${BUILDKITE_PLUGIN_VAULT_SECRETS_AUTH_ROLE:-"buildkite"}",
  "iam_http_request_method": "POST",
  "iam_request_url": "$iam_request_url",
  "iam_request_body": "$iam_request_body",
  "iam_request_headers": "$iam_request_headers"
}
EOF
)
  # Send the login request on stdin (`--data @-`): its signed headers carry the
  # instance's AWS session token, and on curl's command line they would show up
  # in `ps` output for as long as the login takes. printf is a shell builtin, so
  # the request never reaches any command's argv.
  response=$(printf '%s' "$data" | curl --request POST --fail-with-body --data @- "$auth_url")
  export VAULT_TOKEN=$(echo $response | jq -r .auth.client_token)
}

function strip_quotes() {
  echo "${1}" | sed "s/^[[:blank:]]*//g;s/[[:blank:]]*$//g;s/[\"']//g"
}

function get_secret_value() {
  local secretPath="$1"
  local secretKey="$2"
  local secrets;
  echo -e "\033[31m" >&2
  # Pass VAULT_TOKEN by name only: `--env VAULT_TOKEN` with no value tells
  # docker to copy it from its own environment. The token never appears in
  # docker's argv, so it stays out of `ps` output and logs (and out of `set -x`
  # traces, which show only the name here). `--rm` removes the container, and
  # the token in its config, as soon as `vault kv get` exits; vault's errors
  # still reach the job log through docker's stderr.
  export VAULT_TOKEN
  secrets=$(docker run \
      --rm \
      --cap-add IPC_LOCK \
      --env VAULT_TOKEN \
      -- \
      "${image}" \
      vault kv get \
      -address "${VAULT_ADDR}" \
      -format=json \
      "${secretPath}")
  local result=$?
  echo -e "\033[0m" >&2
  if [[ $result -ne 0 ]]; then
    echo "--- :skull_and_crossbones: Could not read '${secretPath}' from Vault (see the error above)" >&2
    exit 1
  fi
  echo "${secrets}" | jq -r .data.data."[\"${secretKey}\"]"
}

load_secret_into_env() {
  local export_name="$1"
  local secret_path="$2"
  local secret_key="$3"
  local secret_value
  echo "Reading ${secret_path}/${secret_key} from Vault into environment variable ${export_name}"
  secret_value="$(get_secret_value "${secret_path}" "${secret_key}")"
  export "${export_name}=${secret_value}"
}
