#!/bin/bash
#=============================================================================
# FORTRESS.SH Permission Repair
#
# Recovery tool for systems damaged by the old fix_permissions.sh
# (upstream issues #22 and #26). That script stripped world read/execute from
# system paths, which produces:
#
#   flatpak: error while loading shared libraries: libappstream.so.5:
#            cannot open shared object file: Permission denied
#   sudo: /usr/bin/sudo must be owned by uid 0 and have the setuid bit set
#   ...and, on Debian 13, an unbootable system.
#
# Root can still read everything, so every root-run check passes while normal
# users are locked out. This restores the world bits and the setuid binaries.
#
# Usage:
#   sudo ./repair_permissions.sh            # report only, changes nothing
#   sudo ./repair_permissions.sh --apply    # actually repair
#=============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

APPLY=false
[[ "${1:-}" == "--apply" ]] && APPLY=true

if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED}Must run as root:${NC} sudo $0 ${*:-}"
    exit 1
fi

# ponytail: fixed list of paths rather than a config file. These are where
# Debian/Ubuntu keep libraries and binaries; add more only if a real system
# turns up needing them.
LIB_DIRS=(/lib /lib64 /usr/lib /usr/lib32 /usr/lib64 /usr/libexec /usr/local/lib)
BIN_DIRS=(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin)

# Binaries that need the setuid bit. Losing it breaks sudo (issue #22), and
# losing sudo on a machine with root login disabled means console-only recovery.
#
# Deliberately NOT a table of expected modes: the exact mode is distro- and
# version-specific (Debian 13 ships dbus-daemon-launch-helper 4754, not the
# 4750 an earlier version of this script asserted), so a hardcoded table
# produces false positives and then "repairs" correct files. The invariant
# that actually matters is: setuid bit set, owned by root.
SETUID_BINS=(
    /usr/bin/sudo
    /usr/bin/su
    /usr/bin/passwd
    /usr/bin/chsh
    /usr/bin/chfn
    /usr/bin/newgrp
    /usr/bin/gpasswd
    /usr/bin/mount
    /usr/bin/umount
    /usr/bin/pkexec
    /usr/bin/fusermount3
    /usr/lib/dbus-1.0/dbus-daemon-launch-helper
    /usr/lib/openssh/ssh-keysign
    /usr/lib/polkit-1/polkit-agent-helper-1
)

FOUND=0
FIXED=0

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  FORTRESS.SH Permission Repair"
echo "════════════════════════════════════════════════════════════════"
if ${APPLY}; then
    echo -e "  Mode: ${YELLOW}APPLY${NC} - changes will be made"
else
    echo -e "  Mode: ${GREEN}REPORT ONLY${NC} - re-run with --apply to repair"
fi
echo ""

#-----------------------------------------------------------------------------
# 1. Shared libraries and their directories
#-----------------------------------------------------------------------------
echo -e "${BLUE}[1] Library read/execute permissions${NC}"
echo "─────────────────────────────────────────────────"

for dir in "${LIB_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue

    # Directories need o+rx or nothing underneath them can be reached.
    bad_dirs=$(find "${dir}" -type d ! -perm -o+rx 2>/dev/null)
    # Regular files need o+r; o+X adds execute only where it already exists.
    bad_files=$(find "${dir}" -type f ! -perm -o+r 2>/dev/null)

    n=0
    [[ -n "${bad_dirs}" ]] && n=$((n + $(echo "${bad_dirs}" | wc -l)))
    [[ -n "${bad_files}" ]] && n=$((n + $(echo "${bad_files}" | wc -l)))

    if [[ ${n} -eq 0 ]]; then
        echo -e "  ${GREEN}✓${NC} ${dir}"
        continue
    fi

    FOUND=$((FOUND + n))
    echo -e "  ${RED}✗${NC} ${dir}: ${n} path(s) unreachable by normal users"
    { [[ -n "${bad_dirs}" ]] && echo "${bad_dirs}"; [[ -n "${bad_files}" ]] && echo "${bad_files}"; } \
        | head -5 | sed 's/^/        /'
    [[ ${n} -gt 5 ]] && echo "        ... and $((n - 5)) more"

    if ${APPLY}; then
        # o+rX: read for all, execute only where the owner already has it.
        # Never touches setuid/setgid bits or ownership.
        chmod -R o+rX "${dir}" 2>/dev/null
        FIXED=$((FIXED + n))
        echo -e "      ${GREEN}repaired${NC}"
    fi
done

echo ""

#-----------------------------------------------------------------------------
# 2. Binary directories
#-----------------------------------------------------------------------------
echo -e "${BLUE}[2] Binary permissions${NC}"
echo "─────────────────────────────────────────────────"

for dir in "${BIN_DIRS[@]}"; do
    [[ -d "${dir}" ]] || continue

    bad=$(find "${dir}" -type f ! -perm -o+rx 2>/dev/null)
    if [[ -z "${bad}" ]]; then
        echo -e "  ${GREEN}✓${NC} ${dir}"
        continue
    fi

    n=$(echo "${bad}" | wc -l)
    FOUND=$((FOUND + n))
    echo -e "  ${RED}✗${NC} ${dir}: ${n} binary/binaries not executable by normal users"
    echo "${bad}" | head -5 | sed 's/^/        /'

    if ${APPLY}; then
        chmod o+rx "${dir}" 2>/dev/null
        echo "${bad}" | while read -r f; do chmod o+rx "${f}" 2>/dev/null; done
        FIXED=$((FIXED + n))
        echo -e "      ${GREEN}repaired${NC}"
    fi
done

echo ""

#-----------------------------------------------------------------------------
# 3. Setuid binaries
#-----------------------------------------------------------------------------
echo -e "${BLUE}[3] Setuid binaries${NC}"
echo "─────────────────────────────────────────────────"

for bin in "${SETUID_BINS[@]}"; do
    [[ -f "${bin}" ]] || continue

    have=$(stat -c '%a' "${bin}" 2>/dev/null)
    owner=$(stat -c '%u' "${bin}" 2>/dev/null)

    if [[ -u "${bin}" ]] && [[ "${owner}" == "0" ]]; then
        echo -e "  ${GREEN}✓${NC} ${bin} (${have})"
        continue
    fi

    FOUND=$((FOUND + 1))
    if [[ ! -u "${bin}" ]]; then
        echo -e "  ${RED}✗${NC} ${bin}: setuid bit missing (mode ${have})"
    else
        echo -e "  ${RED}✗${NC} ${bin}: owned by uid ${owner}, must be uid 0"
    fi

    if ${APPLY}; then
        # Restore only the invariant. The group/other bits are handled by the
        # o+rX passes above; do not overwrite a distro-specific mode.
        chown root "${bin}" 2>/dev/null
        chmod u+s "${bin}" 2>/dev/null
        FIXED=$((FIXED + 1))
        echo -e "      ${GREEN}repaired${NC}"
    fi
done

echo ""

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
echo "════════════════════════════════════════════════════════════════"
if [[ ${FOUND} -eq 0 ]]; then
    echo -e "  ${GREEN}No permission damage found.${NC}"
    echo ""
    echo "  If apps still fail with 'Permission denied', the cause is not file"
    echo "  modes. Check AppArmor denials instead:"
    echo "    sudo journalctl -k | grep 'apparmor=\"DENIED\"'"
elif ${APPLY}; then
    echo -e "  ${GREEN}Repaired ${FIXED} path(s).${NC}"
    echo ""
    echo "  Next: log out and back in, then run ./verify_fortress.sh"
    echo "  If a package is still broken, reinstall it:"
    echo "    sudo apt-get install --reinstall <package>"
else
    echo -e "  ${YELLOW}Found ${FOUND} damaged path(s). Nothing changed.${NC}"
    echo ""
    echo "  To repair: sudo $0 --apply"
fi
echo "════════════════════════════════════════════════════════════════"
echo ""
