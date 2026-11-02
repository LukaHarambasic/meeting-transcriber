#!/usr/bin/env bash
# Regression test for scripts/build_release.sh codesign-identity detection.
#
# Bug history:
#   `SIGN_HASH=$(security find-identity ... | grep | head -1)` aborted under
#   `set -euo pipefail` when no codesign identity existed (grep exits 1 on
#   no match → pipefail → set -e). Fixed by appending `|| true`.
#
# This test sources build_release.sh and calls detect_sign_hash() directly
# with a PATH-stubbed `security` to simulate "no identity installed".

set -uo pipefail   # NOT -e: harness keeps running on test failure

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

FAILED=0

run_test() {
    local name="$1"
    printf '%s ... ' "$name"
    if "$name"; then printf 'PASS\n'; else printf 'FAIL\n'; FAILED=1; fi
}

# Creates a stub PATH directory containing a no-op `security` and prints its path.
# Caller is responsible for cleanup.
make_security_stub() {
    local dir
    dir=$(mktemp -d)
    cat > "$dir/security" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$dir/security"
    printf '%s' "$dir"
}

test_detect_sign_hash_empty_when_no_identity() {
    local stub_dir result rc
    stub_dir=$(make_security_stub)
    # Expand $stub_dir now (single command string), not at RETURN time —
    # the local goes out of scope when the function returns.
    trap "rm -rf -- '$stub_dir'" RETURN

    result=$(PATH="$stub_dir:$PATH" bash -c "set -euo pipefail; source '$REPO_ROOT/scripts/build_release.sh'; detect_sign_hash")
    rc=$?

    if [ "$rc" -ne 0 ]; then
        echo
        echo "  detect_sign_hash aborted with exit $rc under set -euo pipefail"
        return 1
    fi
    if [ -n "$result" ]; then
        echo
        echo "  expected empty result, got: $result"
        return 1
    fi
    return 0
}

# Creates a stub PATH directory whose `security` appends its arguments to
# $dir/calls, and prints the directory.
make_recording_security_stub() {
    local dir
    dir=$(mktemp -d)
    cat > "$dir/security" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$dir/calls'
exit 0
EOF
    chmod +x "$dir/security"
    printf '%s' "$dir"
}

# The signing identity lives in a keychain created with an empty password; a
# locked one makes codesign ask for a password nobody knows, or fail with
# errSecInternalComponent where no dialog can be shown.
test_unlock_dev_keychain_unlocks_with_empty_password() {
    local stub_dir keychain
    stub_dir=$(make_recording_security_stub)
    trap "rm -rf -- '$stub_dir'" RETURN
    keychain="$stub_dir/dev.keychain-db"
    : > "$keychain"

    PATH="$stub_dir:$PATH" DEV_KEYCHAIN="$keychain" \
        bash -c "set -euo pipefail; source '$REPO_ROOT/scripts/build_release.sh'; unlock_dev_keychain"

    local expected="unlock-keychain -p  $keychain"
    if ! grep -qxF -- "$expected" "$stub_dir/calls" 2>/dev/null; then
        echo
        echo "  expected security call: $expected"
        echo "  got: $(cat "$stub_dir/calls" 2>/dev/null)"
        return 1
    fi
    return 0
}

test_unlock_dev_keychain_skips_missing_keychain() {
    local stub_dir
    stub_dir=$(make_recording_security_stub)
    trap "rm -rf -- '$stub_dir'" RETURN

    PATH="$stub_dir:$PATH" DEV_KEYCHAIN="$stub_dir/absent.keychain-db" \
        bash -c "set -euo pipefail; source '$REPO_ROOT/scripts/build_release.sh'; unlock_dev_keychain" \
        || { echo; echo "  aborted on a missing keychain"; return 1; }

    if [ -s "$stub_dir/calls" ]; then
        echo
        echo "  expected no security call, got: $(cat "$stub_dir/calls")"
        return 1
    fi
    return 0
}

# The helper only helps if the local signing branch calls it before looking up
# the identity. The build itself cannot run here, so this reads the script.
test_local_signing_unlocks_before_detecting() {
    local unlock_line detect_line
    unlock_line=$(grep -n '^    unlock_dev_keychain$' "$REPO_ROOT/scripts/build_release.sh" | cut -d: -f1)
    detect_line=$(grep -n 'SIGN_HASH=\$(detect_sign_hash)' "$REPO_ROOT/scripts/build_release.sh" | cut -d: -f1)
    if [ -z "$unlock_line" ] || [ -z "$detect_line" ] || [ "$unlock_line" -ge "$detect_line" ]; then
        echo
        echo "  unlock_dev_keychain must be called right before detect_sign_hash"
        return 1
    fi
    return 0
}

run_test test_detect_sign_hash_empty_when_no_identity
run_test test_unlock_dev_keychain_unlocks_with_empty_password
run_test test_unlock_dev_keychain_skips_missing_keychain
run_test test_local_signing_unlocks_before_detecting

exit "$FAILED"
