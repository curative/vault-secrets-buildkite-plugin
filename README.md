# Vault Secrets Buildkite Plugin

Provides Secrets stored in Vault as environment variables in buildkite pipeline

Only support KVV2 vault secrets backend.

## Example

Add the following to your `pipeline.yml`:

### Example with Vault Token
```yml
steps:
  - command: ls
    plugins:
      - vj396/vault-secrets#v0.1.0:
          image: 'vault' # optional. Defaults to https://hub.docker.com/_/vault
          tag: "1.10.2" # optional. Defaults to 1.10.2
          address: "http://vault-server:8200" # optional. plugin will error when VAULT_ADDR is also not in env.
          token: "123ASda" # optional. plugin will error when VAULT_TOKEN is also not in env. 
          env:
            MY_SECRET: secret/foo # where foo is the secret key
            MY_OTHER_SECRET: secret/path/foo # Where secret/path is the vault path to the secret and foo is the secret key
```

### Example with Auth Metadata
```yml
steps:
  - command: ls
    plugins:
      - vj396/vault-secrets#v0.1.0:
          image: 'vault' # optional. Defaults to https://hub.docker.com/_/vault
          tag: "1.10.2" # optional. Defaults to 1.10.2
          address: "http://vault-server:8200" # optional. plugin will error when VAULT_ADDR is also not in env.
          auth:
            method: aws # optional. defaults to vault login method `aws`
            role: example-role # optional. defaults to vault aws auth role `buildkite`
            path: aws/custom/path # optional. Vault Auth backend path. defaults to `aws`
            header: vault.service.consul # optional. Defaults to vault_addr server name
          env:
            MY_SECRET: secret/foo # where foo is the secret key
            MY_OTHER_SECRET: secret/path/foo # Where secret/path is the vault path to the secret and foo is the secret key
```
## Developing

### Test
```shell
vault kv put secrets/buildkite/test foo1=bar foo=bar
BUILDKITE_PLUGIN_VAULT_ENV_SECRETS_ENV_FOO1=secrets/buildkite/test/foo1 BUILDKITE_PLUGIN_VAULT_ENV_SECRETS_ENV_FOO=secrets/buildkite/test/foo  BUILDKITE_JOB_ID=123 VAULT_TOKEN=$(cat ~/.vault-token) ./hooks/environment
```

### Token handling check
`tests/token_not_in_docker_argv.sh` runs the environment hook against a stub `docker` with a dummy token, for the `token` option, an inherited `VAULT_TOKEN` and the AWS auth path. It checks that the token is passed to `docker run` as a bare `--env VAULT_TOKEN` (copied from docker's environment) and never appears in docker's argv, where it would show up in `ps` output and logs. It needs only bash and jq, and runs in GitHub Actions on every pull request.

```shell
./tests/token_not_in_docker_argv.sh
```

## TODO
1. Add vault auth support

## Contributing

1. Fork the repo
2. Make the changes
3. Run the tests
4. Commit and push your changes
5. Send a pull request