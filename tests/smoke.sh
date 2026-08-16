#!/bin/sh
set -eu

BINARY=${1:-build/macbook-dock-brightness}
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/macbook-dock-brightness-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

VERSION=$($BINARY --version)
[ "$VERSION" = "0.1.0" ]

$BINARY --help | grep -q -- "--restore"
$BINARY --list-displays | grep -q "ID  TYPE"

cp config.example.json "$TEST_ROOT/config.json"
MDB_CONFIG_PATH="$TEST_ROOT/config.json" $BINARY --validate-config | grep -q "Configuration is valid"
if $BINARY --list-displays | grep -q "built-in"; then
    MDB_CONFIG_PATH="$TEST_ROOT/config.json" $BINARY --dry-run | grep -q "target="
fi

printf '%s\n' '{"schemaVersion":1}' > "$TEST_ROOT/invalid.json"
if MDB_CONFIG_PATH="$TEST_ROOT/invalid.json" $BINARY --validate-config >/dev/null 2>&1; then
    echo "invalid configuration unexpectedly passed" >&2
    exit 1
fi

if ! MDB_CONFIG_PATH="$TEST_ROOT/invalid.json" $BINARY --daemon >/dev/null 2>&1; then
    echo "daemon did not fail cleanly for an invalid configuration" >&2
    exit 1
fi

cat > "$TEST_ROOT/malformed-container.json" <<'EOF'
{
  "schemaVersion": 1,
  "targetDisplay": 5,
  "brightness": {},
  "autoBrightness": {}
}
EOF
if MDB_CONFIG_PATH="$TEST_ROOT/malformed-container.json" \
    $BINARY --validate-config >/dev/null 2>&1; then
    echo "malformed configuration containers unexpectedly passed" >&2
    exit 1
fi

cp config.example.json "$TEST_ROOT/managed-config.json"
printf '%s\n' '{"schemaVersion":1,"managed":true}' > "$TEST_ROOT/state.json"
MDB_CONFIG_PATH="$TEST_ROOT/managed-config.json" MDB_STATE_PATH="$TEST_ROOT/state.json" \
    $BINARY --dry-run >/dev/null
[ -f "$TEST_ROOT/state.json" ]

if MDB_CONFIG_PATH="$TEST_ROOT/missing-target.json" \
    $BINARY --init-config >/dev/null 2>&1; then
    echo "configuration initialization unexpectedly guessed a target" >&2
    exit 1
fi

./scripts/install.sh --dry-run | grep -q "Would install"
./scripts/uninstall.sh --dry-run | grep -q "Would restore"

echo "smoke tests passed"
