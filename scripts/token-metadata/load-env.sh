#!/usr/bin/env bash
# Source Pinata / token-metadata secrets from gitignored env files.
# Does not override vars already set in the environment.
: "${ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

_load_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    case "$key" in
      PINATA_JWT|PINATA_GATEWAY|EXTERNAL_URL|TOKEN_ICON_URI|TOKEN_METADATA_URI|TOKEN_LIST_URI) ;;
      *) continue ;;
    esac
    if [[ -n "${!key+x}" ]]; then
      continue
    fi
    val="${line#*=}"
    export "$key=$val"
  done <"$f"
}

_load_env_file "$ROOT/.env"
_load_env_file "$ROOT/evm/.env.secrets"
_load_env_file "$ROOT/packages/token-metadata/.env"
_load_env_file "$ROOT/evm/.env.${CLUSTER:-arbitrum}"
_load_env_file "$ROOT/packages/token-metadata/deployed.env"
