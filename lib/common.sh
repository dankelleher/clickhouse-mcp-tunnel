# Shared helpers for ch-tunnel and clickhouse-mcp-tunnel.
# Sourced, not executed.

CMT_CONFIG_DIR="${CMT_CONFIG_DIR:-$HOME/.config/clickhouse-mcp-tunnel}"
CMT_STATE_DIR="${CMT_STATE_DIR:-$HOME/.cache/clickhouse-mcp-tunnel}"

die() { echo "${0##*/}: $*" >&2; exit 1; }

# Resolve this script's real location so a symlink in ~/.local/bin still finds
# lib/. macOS ships a readlink without -f on older releases, so walk it manually.
cmt_script_dir() {
  local src="$1" dir
  while [ -L "$src" ]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")" && pwd
}

# Profile config is a plain KEY=VALUE file. It holds no secrets — those live in
# the keychain — but it does name internal hosts, so it stays out of git.
cmt_load_profile() {
  local profile="$1"
  local file="$CMT_CONFIG_DIR/$profile.env"
  [ -f "$file" ] || die "no profile '$profile' at $file (run install.sh)"
  # shellcheck disable=SC1090
  . "$file"

  : "${AWS_REGION:=eu-west-1}"
  : "${REMOTE_PORT:=8443}"
  : "${LOCAL_PORT:=}"
  : "${KEYCHAIN_SERVICE:=clickhouse-mcp-$profile}"
  : "${SERVER_NAME:=clickhouse}"

  [ -n "${AWS_PROFILE:-}" ] || die "profile '$profile' sets no AWS_PROFILE"
  [ -n "$LOCAL_PORT" ]      || die "profile '$profile' sets no LOCAL_PORT"
  [ -n "${BASTION:-}" ]     || die "profile '$profile' sets no BASTION"
  [ -n "${REMOTE_HOST:-}${REMOTE_HOST_SSM_PARAM:-}" ] \
    || die "profile '$profile' needs REMOTE_HOST or REMOTE_HOST_SSM_PARAM"

  CMT_PROFILE="$profile"
  mkdir -p "$CMT_STATE_DIR"
}

cmt_aws() { AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" aws "$@"; }

# The endpoint hostname can be pinned in the profile or read from SSM, so a
# re-provisioned service needs no edit here.
cmt_remote_host() {
  if [ -n "${REMOTE_HOST:-}" ]; then printf '%s' "$REMOTE_HOST"; return 0; fi
  local host
  host="$(cmt_aws ssm get-parameter --name "$REMOTE_HOST_SSM_PARAM" \
            --query 'Parameter.Value' --output text 2>/dev/null)"
  [ -n "$host" ] && [ "$host" != None ] || return 1
  printf '%s' "$host"
}

# BASTION is either an instance id or a Name tag to resolve.
cmt_bastion_id() {
  case "$BASTION" in
    i-*|mi-*) printf '%s' "$BASTION"; return 0 ;;
  esac
  local id
  id="$(cmt_aws ec2 describe-instances \
          --filters "Name=tag:Name,Values=$BASTION" \
                    "Name=instance-state-name,Values=running" \
          --query 'Reservations[].Instances[0].InstanceId' --output text 2>/dev/null)"
  [ -n "$id" ] && [ "$id" != None ] || return 1
  printf '%s' "$id"
}

cmt_listening() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

# A bound port is not a working tunnel: a dead SSM session keeps its local socket
# and fails on the first byte. Only an end-to-end request settles it. The host is
# passed in so callers polling in a loop resolve it once.
cmt_healthy() {
  local port="$1" host="$2"
  cmt_listening "$port" || return 1
  curl -sf -m 8 --resolve "${host}:${port}:127.0.0.1" \
    "https://${host}:${port}/ping" 2>/dev/null | grep -q Ok
}

# Drop a listener that is bound but not carrying traffic, so a fresh session can
# claim the port.
cmt_kill_stale() {
  local port="$1" pidfile="$CMT_STATE_DIR/$CMT_PROFILE.pid" pid holder i
  pid="$(cat "$pidfile" 2>/dev/null)"
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  # The SSM plugin is a child of the aws CLI, so target whatever holds the port.
  holder="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null)"
  [ -n "$holder" ] && kill $holder 2>/dev/null
  rm -f "$pidfile"
  for i in 1 2 3 4 5; do cmt_listening "$port" || return 0; sleep 1; done
}

# Log in only when a human is there to complete the browser flow. Called from an
# MCP server there is no TTY, so fail with an instruction instead of hanging.
cmt_require_creds() {
  aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1 && return 0
  if [ -t 0 ] && [ -t 1 ]; then
    aws sso login --profile "$AWS_PROFILE" >&2 && return 0
  fi
  echo "${0##*/}: AWS credentials for '$AWS_PROFILE' are expired." >&2
  echo "${0##*/}: authenticate in a terminal, then retry." >&2
  return 1
}
