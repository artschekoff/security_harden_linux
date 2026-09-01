#!/bin/bash
#=============================================================================
# Self-check for the issue fixes. No framework, no fixtures.
#   ./test_fixes.sh
# Exits non-zero if a fix regressed.
#=============================================================================

set -uo pipefail
cd "$(dirname "$0")" || exit 1

PASS=0
FAIL=0

ok()   { echo "  ok   - $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL - $1"; FAIL=$((FAIL + 1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', want '$3')"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "${TMP}"' EXIT

echo "== syntax =="
for f in fortress_improved.sh verify_fortress.sh repair_permissions.sh PERM_diagnostic.sh; do
    if bash -n "$f" 2>/dev/null; then ok "$f parses"; else bad "$f parses"; fi
done

#-----------------------------------------------------------------------------
echo "== issue #25: complain-mode profiles are not force-enforced =="
#-----------------------------------------------------------------------------
# Same regex as module_apparmor().
COMPLAIN_RE='flags[[:space:]]*=[[:space:]]*\([^)]*complain'

cat > "${TMP}/usr.sbin.php-fpm" <<'EOF'
profile php-fpm /usr/sbin/php-fpm8.2 flags=(complain) {
  #include <abstractions/base>
}
EOF
cat > "${TMP}/usr.sbin.tcpdump" <<'EOF'
/usr/bin/tcpdump {
  #include <abstractions/base>
}
EOF
cat > "${TMP}/spaced" <<'EOF'
profile foo /usr/bin/foo flags = ( attach_disconnected , complain ) {
}
EOF

matched=""
for p in "${TMP}"/usr.sbin.php-fpm "${TMP}"/usr.sbin.tcpdump "${TMP}"/spaced; do
    grep -qE "${COMPLAIN_RE}" "$p" && matched="${matched}$(basename "$p") "
done
check "flags=(complain) detected, plain profile left alone" \
      "${matched}" "usr.sbin.php-fpm spaced "

# Comment lines mentioning the old command are fine; an executable one is not.
grep -v '^[[:space:]]*#' fortress_improved.sh | grep -q 'aa-enforce /etc/apparmor.d/\*' \
    && bad "blanket 'aa-enforce /etc/apparmor.d/*' still executed" \
    || ok "blanket 'aa-enforce /etc/apparmor.d/*' no longer executed"

#-----------------------------------------------------------------------------
echo "== issue #21: failed commands mark the module failed =="
#-----------------------------------------------------------------------------
# Reproduce the call shape: a module invoked as `if "${func}"` has errexit
# suppressed for its whole body, so a mid-module failure used to be stepped
# over and the trailing `return 0` reported success.
run_shape() {
    local guard="$1"
    bash -c '
        set -euo pipefail
        declare -i MODULE_ERROR_COUNT=0
        execute_command() {
            local rc=0
            eval "${2}" || rc=$?
            [[ ${rc} -ne 0 ]] && MODULE_ERROR_COUNT=$((MODULE_ERROR_COUNT + 1))
            return "${rc}"
        }
        module_demo() {
            execute_command "will fail" "false"
            execute_command "will pass" "true"
            return 0
        }
        MODULE_ERROR_COUNT=0
        if module_demo '"${guard}"'; then echo PASSED; else echo FAILED; fi
    '
}
check "old shape wrongly reports success"      "$(run_shape '')"                            "PASSED"
check "new shape reports the module as failed" "$(run_shape '&& [[ ${MODULE_ERROR_COUNT} -eq 0 ]]')" "FAILED"

grep -q 'if "${func}" && \[\[ ${MODULE_ERROR_COUNT} -eq 0 \]\]' fortress_improved.sh \
    && ok "execute_modules checks MODULE_ERROR_COUNT" \
    || bad "execute_modules checks MODULE_ERROR_COUNT"

grep -q 'if \[\[ ! -s "${sysctl_conf}" \]\]' fortress_improved.sh \
    && ok "module_sysctl verifies the file was written" \
    || bad "module_sysctl verifies the file was written"

#-----------------------------------------------------------------------------
echo "== issue #26: non-world-readable libraries are detected =="
#-----------------------------------------------------------------------------
mkdir -p "${TMP}/lib"
printf 'x' > "${TMP}/lib/libgood.so.1"; chmod 644 "${TMP}/lib/libgood.so.1"
printf 'x' > "${TMP}/lib/libappstream.so.5"; chmod 640 "${TMP}/lib/libappstream.so.5"
ln -sf libappstream.so.5 "${TMP}/lib/libappstream.so"

hits=$(find "${TMP}/lib" -name '*.so*' -type f ! -perm -o+r 2>/dev/null | wc -l | tr -d ' ')
check "sweep flags exactly the unreadable .so" "${hits}" "1"

# The symlink is 0777; only the resolved target reveals the problem.
target=$(readlink -f "${TMP}/lib/libappstream.so")
tgt_hits=$(find "${target}" -perm -o+r 2>/dev/null | wc -l | tr -d ' ')
check "resolved symlink target shows as unreadable" "${tgt_hits}" "0"

grep -q 'readlink -f "$FOUND"' verify_fortress.sh \
    && ok "verify_fortress resolves symlinks before checking" \
    || bad "verify_fortress resolves symlinks before checking"

# chmod o+rX must restore read without granting execute on a plain data file.
chmod o+rX "${TMP}/lib/libappstream.so.5"
mode=$(stat -c '%a' "${TMP}/lib/libappstream.so.5" 2>/dev/null || stat -f '%Lp' "${TMP}/lib/libappstream.so.5")
check "o+rX adds read only, no execute bit" "${mode}" "644"

#-----------------------------------------------------------------------------
echo "== setuid check is mode-agnostic =="
#-----------------------------------------------------------------------------
# Found on a real Debian 13 box: it ships dbus-daemon-launch-helper as 4754,
# not the 4750 an earlier version of repair_permissions.sh asserted. A table of
# expected modes flags correct files and then "repairs" them. Only the setuid
# bit and root ownership are portable invariants.
grep -qE '\]=4[0-9]{3}' repair_permissions.sh \
    && bad "hardcoded setuid mode table is back" \
    || ok "no hardcoded setuid mode table"

grep -q '\[\[ -u "${bin}" \]\]' repair_permissions.sh \
    && ok "setuid checked via -u, not an exact mode" \
    || bad "setuid checked via -u, not an exact mode"

printf 'x' > "${TMP}/setuid_bin"
chmod 4754 "${TMP}/setuid_bin" 2>/dev/null
[[ -u "${TMP}/setuid_bin" ]] && ok "4754 accepted as setuid" || bad "4754 accepted as setuid"
chmod 0755 "${TMP}/setuid_bin"
[[ -u "${TMP}/setuid_bin" ]] && bad "0755 wrongly accepted as setuid" || ok "0755 flagged as missing setuid"

echo ""
echo "passed: ${PASS}  failed: ${FAIL}"
[[ ${FAIL} -eq 0 ]]
