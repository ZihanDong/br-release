#!/usr/bin/env bash
# Shared utilities: logging, OS detection, privilege check.

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

# ── Privilege ────────────────────────────────────────────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (or via sudo)."
}

# ── OS Detection ─────────────────────────────────────────────────────────────
# Sets globals: OS_ID  OS_VERSION_ID  OS_CODENAME  PKG_MGR
detect_os() {
    [[ -f /etc/os-release ]] || die "/etc/os-release not found — cannot detect OS."
    # shellcheck source=/dev/null
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION_ID="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"

    case "${OS_ID}" in
        ubuntu)
            PKG_MGR="apt"
            case "${OS_VERSION_ID}" in
                20.04) OS_CODENAME="focal"   ;;
                22.04) OS_CODENAME="jammy"   ;;
                24.04) OS_CODENAME="noble"   ;;
                *) die "Unsupported Ubuntu version: ${OS_VERSION_ID} (supported: 20.04, 22.04, 24.04)" ;;
            esac
            ;;
        kylin)
            PKG_MGR="apt"
            case "${OS_VERSION_ID}" in
                V10|10) OS_CODENAME="focal"; OS_VERSION_ID="V10" ;;
                V11|11) OS_CODENAME="jammy"; OS_VERSION_ID="V11" ;;
                *) die "Unsupported Kylin version: ${OS_VERSION_ID} (supported: V10, V11)" ;;
            esac
            ;;
        *)
            die "Unsupported OS: ${OS_ID}. Supported: ubuntu (20.04/22.04/24.04), kylin (V10/V11)."
            ;;
    esac

    log_info "Detected OS: ${OS_ID} ${OS_VERSION_ID} (${OS_CODENAME})"
}

# ── Version helpers ───────────────────────────────────────────────────────────
# Returns 0 if $1 >= $2 (semver x.y.z, leading 'v' stripped)
version_gte() {
    local a="${1#v}" b="${2#v}"
    printf '%s\n%s\n' "$b" "$a" | sort -V -C
}

# Normalise "1.28" → "1.28.0", strip leading 'v'
normalise_version() {
    local v="${1#v}"
    local parts
    IFS='.' read -ra parts <<< "$v"
    echo "${parts[0]:-1}.${parts[1]:-0}.${parts[2]:-0}"
}

# ── Misc ─────────────────────────────────────────────────────────────────────
command_exists() { command -v "$1" &>/dev/null; }

apt_install() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

yum_install() {
    yum install -y "$@"
}
