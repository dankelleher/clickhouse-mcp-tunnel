#!/usr/bin/env bash
# Install ch-tunnel + clickhouse-mcp-tunnel and create a profile.
#
# Profiles carry the site-specific details (AWS profile, bastion, endpoint) and
# live in ~/.config/clickhouse-mcp-tunnel/<profile>.env, outside this repo.
#
#   ./install.sh                      interactive
#   ./install.sh --profile stg \
#     --aws-profile my-staging \
#     --bastion my-stg-bastion \
#     --remote-host-ssm-param /path/to/hostname \
#     --local-port 18443 --database stg_tsds
#
# Re-running is safe: an existing profile is shown and confirmed before overwrite.

set -euo pipefail

REPO="$(cd -P "$(dirname "$0")" && pwd)"
CONFIG_DIR="${CMT_CONFIG_DIR:-$HOME/.config/clickhouse-mcp-tunnel}"
BIN_DIR="${CMT_BIN_DIR:-$HOME/.local/bin}"

PROFILE=""; AWS_PROFILE_IN=""; AWS_REGION_IN=""; BASTION_IN=""
REMOTE_HOST_IN=""; REMOTE_HOST_SSM_IN=""; REMOTE_PORT_IN=""; LOCAL_PORT_IN=""
DATABASE_IN=""; SERVER_NAME_IN=""; REGISTER=ask

while [ $# -gt 0 ]; do
  case "$1" in
    --profile)              PROFILE="$2"; shift 2 ;;
    --aws-profile)          AWS_PROFILE_IN="$2"; shift 2 ;;
    --region)               AWS_REGION_IN="$2"; shift 2 ;;
    --bastion)              BASTION_IN="$2"; shift 2 ;;
    --remote-host)          REMOTE_HOST_IN="$2"; shift 2 ;;
    --remote-host-ssm-param) REMOTE_HOST_SSM_IN="$2"; shift 2 ;;
    --remote-port)          REMOTE_PORT_IN="$2"; shift 2 ;;
    --local-port)           LOCAL_PORT_IN="$2"; shift 2 ;;
    --database)             DATABASE_IN="$2"; shift 2 ;;
    --server-name)          SERVER_NAME_IN="$2"; shift 2 ;;
    --register)             REGISTER=yes; shift ;;
    --no-register)          REGISTER=no; shift ;;
    -h|--help)              sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

ask() { # ask <prompt> <default>
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then printf '%s [%s]: ' "$prompt" "$default" >&2
  else printf '%s: ' "$prompt" >&2; fi
  read -r reply || true
  printf '%s' "${reply:-$default}"
}

echo "==> checking prerequisites" >&2
missing=""
for c in aws uv curl nc lsof security session-manager-plugin; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
[ -n "$missing" ] && { echo "install.sh: missing:$missing" >&2; exit 1; }
echo "    all present" >&2

echo "==> linking scripts into $BIN_DIR" >&2
mkdir -p "$BIN_DIR"
for s in ch-tunnel clickhouse-mcp-tunnel; do
  ln -sfn "$REPO/bin/$s" "$BIN_DIR/$s"
  echo "    $BIN_DIR/$s -> $REPO/bin/$s" >&2
done
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "    note: $BIN_DIR is not on your PATH" >&2 ;;
esac

echo "==> profile" >&2
[ -n "$PROFILE" ] || PROFILE="$(ask 'Profile name (e.g. stg)' stg)"
FILE="$CONFIG_DIR/$PROFILE.env"
if [ -f "$FILE" ]; then
  echo "    $FILE already exists:" >&2
  sed 's/^/      /' "$FILE" >&2
  [ "$(ask 'Overwrite? (y/N)' N)" = y ] || { echo "    keeping existing profile" >&2; exit 0; }
fi

[ -n "$AWS_PROFILE_IN" ] || AWS_PROFILE_IN="$(ask 'AWS profile')"
[ -n "$AWS_REGION_IN" ]  || AWS_REGION_IN="$(ask 'AWS region' eu-west-1)"
[ -n "$BASTION_IN" ]     || BASTION_IN="$(ask 'Bastion instance id (i-...) or Name tag')"

if [ -z "$REMOTE_HOST_IN" ] && [ -z "$REMOTE_HOST_SSM_IN" ]; then
  echo "    The endpoint hostname can be pinned here, or read from SSM at run time" >&2
  echo "    so a re-provisioned service needs no edit." >&2
  REMOTE_HOST_SSM_IN="$(ask 'SSM parameter holding the hostname (blank to pin a literal)')"
  [ -n "$REMOTE_HOST_SSM_IN" ] || REMOTE_HOST_IN="$(ask 'Endpoint hostname')"
fi
[ -n "$REMOTE_PORT_IN" ] || REMOTE_PORT_IN="$(ask 'Remote HTTPS port' 8443)"
[ -n "$LOCAL_PORT_IN" ]  || LOCAL_PORT_IN="$(ask 'Local port' 18443)"
[ -n "$DATABASE_IN" ]    || DATABASE_IN="$(ask 'Default database (blank for none)')"

mkdir -p "$CONFIG_DIR"; chmod 700 "$CONFIG_DIR"
{
  echo "# clickhouse-mcp-tunnel profile '$PROFILE'. No secrets here: credentials"
  echo "# live in the login keychain under KEYCHAIN_SERVICE."
  echo "AWS_PROFILE=$AWS_PROFILE_IN"
  echo "AWS_REGION=$AWS_REGION_IN"
  echo "BASTION=$BASTION_IN"
  [ -n "$REMOTE_HOST_IN" ]     && echo "REMOTE_HOST=$REMOTE_HOST_IN"
  [ -n "$REMOTE_HOST_SSM_IN" ] && echo "REMOTE_HOST_SSM_PARAM=$REMOTE_HOST_SSM_IN"
  echo "REMOTE_PORT=$REMOTE_PORT_IN"
  echo "LOCAL_PORT=$LOCAL_PORT_IN"
  [ -n "$DATABASE_IN" ] && echo "CLICKHOUSE_DATABASE=$DATABASE_IN"
  echo "KEYCHAIN_SERVICE=clickhouse-mcp-$PROFILE"
} > "$FILE"
chmod 600 "$FILE"
echo "    wrote $FILE" >&2

echo "==> credentials" >&2
if security find-generic-password -s "clickhouse-mcp-$PROFILE" >/dev/null 2>&1; then
  echo "    keychain item 'clickhouse-mcp-$PROFILE' already exists" >&2
else
  echo "    store them with: clickhouse-mcp-tunnel --set-credentials $PROFILE" >&2
fi

echo "==> MCP registration" >&2
if command -v claude >/dev/null 2>&1; then
  [ -n "$SERVER_NAME_IN" ] || SERVER_NAME_IN="clickhouse"
  if [ "$REGISTER" = ask ]; then
    [ "$(ask "Register '$SERVER_NAME_IN' with Claude Code at user scope? (y/N)" N)" = y ] \
      && REGISTER=yes || REGISTER=no
  fi
  if [ "$REGISTER" = yes ]; then
    claude mcp remove "$SERVER_NAME_IN" -s user >/dev/null 2>&1 || true
    claude mcp add -s user "$SERVER_NAME_IN" -- "$BIN_DIR/clickhouse-mcp-tunnel" "$PROFILE"
  else
    echo "    skipped. To do it later:" >&2
    echo "      claude mcp add -s user $SERVER_NAME_IN -- $BIN_DIR/clickhouse-mcp-tunnel $PROFILE" >&2
  fi
else
  echo "    claude CLI not found; register manually if you use Claude Code" >&2
fi

echo >&2
echo "Next: clickhouse-mcp-tunnel --set-credentials $PROFILE" >&2
echo "Then: clickhouse-mcp-tunnel --check $PROFILE" >&2
