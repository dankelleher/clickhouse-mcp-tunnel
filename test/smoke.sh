#!/usr/bin/env bash
# Offline checks: syntax, and the behaviour that does not need AWS or a database.
# Run from anywhere: test/smoke.sh

set -uo pipefail
REPO="$(cd -P "$(dirname "$0")/.." && pwd)"
pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "syntax"
for f in "$REPO"/bin/* "$REPO"/lib/*.sh "$REPO"/install.sh "$0"; do
  check "bash -n $(basename "$f")" "bash -n '$f'"
done

echo "profile validation"
export CMT_CONFIG_DIR="$(mktemp -d)"
export CMT_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$CMT_CONFIG_DIR" "$CMT_STATE_DIR"' EXIT

check "missing profile is rejected" \
  "! '$REPO/bin/ch-tunnel' --port nope"

printf 'AWS_PROFILE=x\nBASTION=i-123\nREMOTE_HOST=h.example\n' > "$CMT_CONFIG_DIR/noport.env"
check "profile without LOCAL_PORT is rejected" \
  "! '$REPO/bin/ch-tunnel' --port noport"

printf 'AWS_PROFILE=x\nLOCAL_PORT=19999\nBASTION=i-123\n' > "$CMT_CONFIG_DIR/nohost.env"
check "profile without a host source is rejected" \
  "! '$REPO/bin/ch-tunnel' --port nohost"

printf 'AWS_PROFILE=x\nLOCAL_PORT=19999\nBASTION=i-123\nREMOTE_HOST=h.example\n' > "$CMT_CONFIG_DIR/good.env"
check "valid profile reports its port" \
  "test \"\$('$REPO/bin/ch-tunnel' --port good)\" = 19999"

echo "cli surface"
check "--help exits 0"            "'$REPO/bin/ch-tunnel' --help"
check "unknown option is rejected" "! '$REPO/bin/ch-tunnel' --bogus good"
check "no argument is rejected"    "! '$REPO/bin/ch-tunnel'"
check "install.sh --help exits 0"  "'$REPO/install.sh' --help"

echo "no site specifics committed"
# The repo must not carry any organisation's hostnames, account ids or SSM paths.
check "no vpce hostnames" \
  "! grep -rIl --exclude-dir=.git -E '[a-z0-9]{8,}\.[a-z0-9-]+\.vpce\.aws\.clickhouse\.cloud' '$REPO'"
check "no aws account ids" \
  "! grep -rIl --exclude-dir=.git -E '\b[0-9]{12}\b' '$REPO'"
check "no real instance ids" \
  "! grep -rIl --exclude-dir=.git -E 'i-[0-9a-f]{17}' '$REPO'"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
