#!/usr/bin/env bash
# =============================================================================
# CS-Traefik - Unified Installer & Setup Wizard
# =============================================================================
# Single entry point for both first-time install and local re-configuration.
# Mode is auto-detected:
#
#   * Standalone (curl | bash):
#       Repository is not yet on disk. Installer:
#         1. Installs missing prerequisites (git, curl, openssl, Docker).
#         2. Clones the repo to /opt/edgeproxy.
#         3. Re-execs itself from the clone (so step 4+ run with full paths).
#         4. Runs the .env wizard.
#         5. Brings the stack up via traefik.sh start.
#
#   * Local checkout (./install.sh):
#       Repository is already on disk (./docker-compose.yml + ./.env.example
#       sit next to this script). Installer just runs the wizard, optionally
#       starting the stack at the end.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh \
#     | sudo bash
#
#   curl -fsSL <repo>/install.sh | sudo bash -s -- --yes      # non-interactive
#   curl -fsSL <repo>/install.sh | sudo bash -s -- --no-start # don't start
#
#   sudo ./install.sh                 # local: re-run the wizard
#   sudo ./install.sh --setup-only    # local: just edit .env, no start
#   sudo ./install.sh --reconfigure   # local: overwrite existing .env
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Static configuration
# -----------------------------------------------------------------------------
REPO_URL="${CS_TRAEFIK_REPO_URL:-https://github.com/bauer-group/CS-Traefik.git}"
INSTALL_DIR_DEFAULT="${CS_TRAEFIK_INSTALL_DIR:-/opt/edgeproxy}"
BRANCH_DEFAULT="${CS_TRAEFIK_BRANCH:-main}"

# -----------------------------------------------------------------------------
# Colors / output
# -----------------------------------------------------------------------------
# ANSI-C ($'...') quoting stores the actual ESC byte (0x1B) in the variable,
# not the 7-character literal "\033[...". This makes `cat <<EOF` work
# correctly alongside `echo -e` and `printf '%b'` -- otherwise heredoc
# output emits literal `\033[1m` text, which is the wrong rendering on
# every terminal that's set up correctly.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

print_banner() {
    echo -e "${BLUE}"
    echo "==============================================================================="
    echo "                       CS-Traefik - BAUER GROUP"
    echo "                  Modern Reverse-Proxy Stack (Traefik v3)"
    echo "==============================================================================="
    echo -e "${NC}"
}
print_section() {
    echo
    echo -e "${CYAN}${BOLD}>> $1${NC}"
    echo -e "${CYAN}-------------------------------------------------------------------------------${NC}"
}
print_info()    { echo -e "${BLUE}-->${NC} $1"; }
print_success() { echo -e "${GREEN}OK${NC}  $1"; }
print_warning() { echo -e "${YELLOW}!!${NC}  $1"; }
print_error()   { echo -e "${RED}XX${NC}  $1"; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
INTERACTIVE=true
RUN_WIZARD=true
START_STACK=true
RECONFIGURE=false
INSTALL_DIR="$INSTALL_DIR_DEFAULT"
BRANCH="$BRANCH_DEFAULT"
UPGRADE_MODE=false
AUTO_UPGRADE=false
DRY_RUN=false
UPGRADE_SOURCE=""

usage() {
    cat <<EOF
CS-Traefik - Unified Installer & Setup Wizard

Usage:
  curl -fsSL <repo>/install.sh | sudo bash [-- options]   # remote bootstrap
  sudo ./install.sh [command] [options]                   # local re-configure

Commands:
  (none / install)        Default. Fresh install (clone + wizard + start).
  upgrade                 Migrate a legacy v2 stack at /opt/edgeproxy to v3.
                          Stops + backs up the v2 install (rename, never delete),
                          migrates relevant .env values, imports ACME certs,
                          installs v3, starts it. Volumes are preserved; old
                          networks are removed.

Options:
  -y, --yes               Non-interactive: use defaults, generate random secrets,
                          no prompts.
      --reconfigure       Overwrite an existing .env (a backup is kept).
                          Without this flag the wizard skips when .env exists.
      --setup-only        Run wizard only -- do not start the stack.
                          (Same as --no-start; kept for clarity in local use.)
      --no-start          Don't start the stack at the end.
      --no-wizard         Skip the wizard entirely (clone + chmod only;
                          remote-bootstrap mode only).
  -b, --branch BRANCH     Git branch to clone (default: main; remote mode).
  -d, --install-dir DIR   Install path (default: /opt/edgeproxy; remote mode).

Upgrade-only options:
      --auto              Skip the confirmation prompt (for automated batch
                          rollout to many hosts). Implies --yes.
      --dry-run           Show the upgrade plan without executing it.
      --source DIR        Path of the v2 stack to upgrade (default: same
                          as --install-dir, since v2 also defaulted there).
  -h, --help              Show this help.

Environment overrides:
  CS_TRAEFIK_REPO_URL     Override the source repository URL
  CS_TRAEFIK_INSTALL_DIR  Override the install path
  CS_TRAEFIK_BRANCH       Override the branch

Examples:
  # Standard interactive install (remote bootstrap)
  curl -fsSL <repo>/install.sh | sudo bash

  # Non-interactive (CI / cloud-init)
  curl -fsSL <repo>/install.sh | sudo bash -s -- --yes

  # Re-run the wizard locally and overwrite .env
  sudo ./install.sh --reconfigure

  # Edit .env without starting the stack
  sudo ./install.sh --setup-only

  # Upgrade legacy v2 stack at /opt/edgeproxy (interactive)
  sudo ./install.sh upgrade

  # Upgrade with no prompts (for batch rollout)
  sudo ./install.sh upgrade --auto

  # Show what an upgrade would do without executing
  sudo ./install.sh upgrade --dry-run

  # Remote-bootstrap upgrade (curl|bash)
  curl -fsSL <repo>/install.sh | sudo bash -s -- upgrade --auto
EOF
}

# Optional positional command before flags (e.g. "install.sh upgrade --auto").
if [[ $# -gt 0 && "$1" != -* ]]; then
    case "$1" in
        install)             UPGRADE_MODE=false; shift ;;
        upgrade)             UPGRADE_MODE=true;  shift ;;
        help)                usage; exit 0 ;;
        *)                   print_error "Unknown command: $1"; usage; exit 1 ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y)            INTERACTIVE=false; shift ;;
        --reconfigure)       RECONFIGURE=true;  shift ;;
        --setup-only)        START_STACK=false; shift ;;
        --no-start)          START_STACK=false; shift ;;
        --no-wizard)         RUN_WIZARD=false; START_STACK=false; shift ;;
        --branch|-b)         BRANCH="$2";       shift 2 ;;
        --install-dir|-d)    INSTALL_DIR="$2";  shift 2 ;;
        --auto)              AUTO_UPGRADE=true; INTERACTIVE=false; shift ;;
        --dry-run)           DRY_RUN=true; shift ;;
        --source)            UPGRADE_SOURCE="$2"; shift 2 ;;
        --help|-h)           usage; exit 0 ;;
        *)                   print_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
# Mode detection
# -----------------------------------------------------------------------------
# We're in "local" mode if the script was invoked from inside an unpacked
# checkout (i.e. ./docker-compose.yml + ./.env.example exist next to it).
# Otherwise we assume "remote bootstrap" mode (curl|bash, file-on-disk
# without the rest of the repo, etc.).
# BASH_SOURCE may be unset under `set -u` when the script is read from
# stdin (curl | bash), so guard with ${BASH_SOURCE[0]:-$0}.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]] && [[ -f "$SCRIPT_DIR/.env.example" ]]; then
    LOCAL_MODE=true
    PROJECT_ROOT="$SCRIPT_DIR"
else
    LOCAL_MODE=false
    PROJECT_ROOT="$INSTALL_DIR"
fi

# -----------------------------------------------------------------------------
# Pre-flight: root, OS, dependencies
# -----------------------------------------------------------------------------
require_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root."
        if [[ "$LOCAL_MODE" == true ]]; then
            echo "Run with:  sudo $0 $*"
        else
            echo "Run with:  curl -fsSL <repo>/install.sh | sudo bash"
        fi
        exit 1
    fi
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        print_warning "Cannot detect OS (no /etc/os-release). Continuing anyway."
        return
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-unknown}" in
        ubuntu|debian|rocky|alma|rhel|centos|fedora|amzn|opensuse-leap|opensuse-tumbleweed)
            print_success "OS: $PRETTY_NAME"
            ;;
        *)
            print_warning "Untested OS: $PRETTY_NAME -- proceeding anyway."
            ;;
    esac
}

install_pkg() {
    local pkg="$1"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq "$pkg"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q "$pkg"
    elif command -v yum >/dev/null 2>&1; then
        yum install -y -q "$pkg"
    elif command -v zypper >/dev/null 2>&1; then
        zypper -q install -y "$pkg"
    else
        print_error "No supported package manager found. Install '$pkg' manually."
        exit 1
    fi
}

check_or_install() {
    local cmd="$1" pkg="${2:-$1}"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    print_info "Installing missing dependency: $pkg"
    install_pkg "$pkg"
}

ensure_basic_tools() {
    print_info "Checking required tools ..."
    check_or_install git
    check_or_install curl
    check_or_install openssl
    # ca-certificates may not exist as a binary; ignore if package install fails
    if [[ ! -d /etc/ssl/certs ]]; then
        install_pkg ca-certificates 2>/dev/null || true
    fi
    print_success "Basic tools ready"
}

ensure_docker() {
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local version
        version=$(docker --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
        print_success "Docker $version found and running"
        # Verify compose plugin
        if ! docker compose version >/dev/null 2>&1; then
            print_error "docker compose v2 plugin missing. Install 'docker-compose-plugin' manually."
            exit 1
        fi
        return 0
    fi

    print_warning "Docker not detected."
    if [[ "$INTERACTIVE" == true ]]; then
        echo
        local ans
        tty_read "Install Docker via the official convenience script? [Y/n] " ans
        ans=${ans:-Y}
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            print_error "Docker is required. Install it manually, then re-run."
            exit 1
        fi
    fi

    print_info "Installing Docker via https://get.docker.com ..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker

    if ! docker compose version >/dev/null 2>&1; then
        print_error "docker compose v2 plugin missing after install."
        exit 1
    fi
    print_success "Docker installed"
}

# -----------------------------------------------------------------------------
# Remote-bootstrap step: clone / update repo, then re-exec
# -----------------------------------------------------------------------------
# detect_live_v2_stack -- returns 0 (true) if a legacy v2 EDGEPROXY
# stack is currently up on the host (running container with traefik:v2*
# image OR networks named EDGEPROXY / EDGEPROXY_INTERNAL with the
# legacy 100.64/16 + 100.65/16 IPAM). The fresh-install path must NOT
# overwrite a running v2 stack -- that strands networks (the IPAM is
# still claimed in Docker's state) and breaks `traefik.sh start` with
# "Pool overlaps with other one on this address space". Operator should
# use `install.sh upgrade` instead.
detect_live_v2_stack() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 1

    # Containers running a Traefik v2 image
    if docker ps --format '{{.Image}}' 2>/dev/null | grep -qE '^traefik:v2'; then
        return 0
    fi
    # Networks matching the legacy v2 names. Both names cover stacks
    # that used the default project name (EDGEPROXY) and any custom
    # NETWORK_NAME the operator might have used.
    if docker network ls --format '{{.Name}}' 2>/dev/null \
        | grep -qE '^(EDGEPROXY|EDGEPROXY_INTERNAL|edgeproxy|edgeproxy_internal)$'; then
        return 0
    fi
    return 1
}

clone_or_update_repo() {
    # Hard fail if a live v2 stack would collide with the fresh v3 install.
    # Do this BEFORE moving the install dir aside so the operator does not
    # end up with a ".backup-<ts>" directory and a half-broken Docker state.
    if detect_live_v2_stack; then
        print_error "A legacy v2 EDGEPROXY stack appears to be live on this host."
        echo
        print_warning "Fresh install would collide with the v2 networks (subnets"
        print_warning "100.64.0.0/16 + 100.65.0.0/16) and fail at 'traefik.sh start'"
        print_warning "with: 'Pool overlaps with other one on this address space'."
        echo
        print_info "Use the upgrade subcommand instead -- it stops v2 cleanly,"
        print_info "removes the v2 networks, migrates ACME certs, and starts v3:"
        echo
        echo "    curl -fsSL https://raw.githubusercontent.com/bauer-group/CS-Traefik/main/install.sh \\"
        echo "        | sudo bash -s -- upgrade"
        echo
        print_info "Add --auto for unattended/batch rollout (no prompts)."
        print_info "See docs/operations/migration-from-v2.md for the full walkthrough."
        exit 1
    fi

    print_info "Preparing $INSTALL_DIR ..."
    mkdir -p "$(dirname "$INSTALL_DIR")"

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        print_info "Existing checkout detected -- updating to origin/$BRANCH"
        cd "$INSTALL_DIR"
        git fetch --quiet origin
        git reset --hard "origin/$BRANCH"
    else
        if [[ -d "$INSTALL_DIR" ]] && [[ -n "$(ls -A "$INSTALL_DIR" 2>/dev/null || true)" ]]; then
            print_warning "$INSTALL_DIR exists and is not empty (and not a git repo)."
            if [[ "$INTERACTIVE" == true ]]; then
                local ans
                tty_read "Move it aside and clone fresh? [y/N] " ans
                if [[ ! "$ans" =~ ^[Yy]$ ]]; then
                    print_error "Aborted by user."
                    exit 1
                fi
            fi
            local backup
            backup="${INSTALL_DIR}.backup.$(date +%Y%m%d_%H%M%S)"
            mv "$INSTALL_DIR" "$backup"
            print_warning "Old contents moved to $backup"
        fi
        rm -rf "$INSTALL_DIR"
        git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$INSTALL_DIR"
        cd "$INSTALL_DIR"
    fi

    git config core.fileMode false 2>/dev/null || true
    git config --global --add safe.directory "$INSTALL_DIR" 2>/dev/null || true

    chmod +x "$INSTALL_DIR"/*.sh 2>/dev/null || true
    print_success "Repository ready at $INSTALL_DIR"
}

# Re-execute the script from the local clone so the rest of the run sees
# the repo's docker-compose / .env.example. Argument pass-through preserves
# --yes / --branch / etc. CS_TRAEFIK_REEXEC tells the second invocation to
# skip the banner + prereq checks (already done in this pass).
re_exec_from_clone() {
    print_info "Continuing setup from the local clone ..."
    CS_TRAEFIK_REEXEC=1 exec "$INSTALL_DIR/install.sh" "$@"
}

# =============================================================================
# Wizard mode (LOCAL_MODE=true) -- runs the .env questionnaire
# =============================================================================

ENV_EXAMPLE="$PROJECT_ROOT/.env.example"
ENV_FILE="$PROJECT_ROOT/.env"

# tty_read -- like `read -rp PROMPT VARNAME`, but reads from /dev/tty when
# stdin is not a TTY (the curl|bash case: stdin holds the script content,
# so a plain `read` would consume script bytes as the answer). Falls back
# to a clear error if neither stdin nor /dev/tty are usable for input.
tty_read() {
    local prompt="$1" varname="$2"
    if [[ -t 0 ]]; then
        # stdin is the user's terminal -- normal case (./install.sh upgrade)
        read -rp "$prompt" "$varname"
    elif [[ -r /dev/tty ]]; then
        # stdin is the script body (curl|bash) -- read from the controlling tty
        read -rp "$prompt" "$varname" </dev/tty
    else
        # Headless context (cron, ssh -T without -tt, docker exec without -i)
        print_error "Interactive input required but no TTY available."
        print_error "Run with --yes (install) / --auto (upgrade) for non-interactive mode."
        exit 1
    fi
}

# tty_read_silent -- like tty_read, but suppresses input echo (passwords).
# Same /dev/tty fallback so curl|bash flows can prompt for secrets.
tty_read_silent() {
    local prompt="$1" varname="$2"
    if [[ -t 0 ]]; then
        read -rsp "$prompt" "$varname"
        echo
    elif [[ -r /dev/tty ]]; then
        read -rsp "$prompt" "$varname" </dev/tty
        echo
    else
        print_error "Interactive password input required but no TTY available."
        print_error "Run with --yes for non-interactive mode (random password)."
        exit 1
    fi
}

ask() {
    # ask "Prompt text" "default-value"  -> echoes the user's answer
    local prompt="$1" default="${2:-}"
    if [[ "$INTERACTIVE" == false ]]; then
        echo "$default"
        return
    fi
    local response
    if [[ -n "$default" ]]; then
        tty_read "$(echo -e "${BOLD}? ${prompt}${NC} [${YELLOW}${default}${NC}]: ")" response
        echo "${response:-$default}"
    else
        tty_read "$(echo -e "${BOLD}? ${prompt}${NC}: ")" response
        echo "$response"
    fi
}

ask_yes_no() {
    # ask_yes_no "Question" "Y|N" -> echoes "yes" or "no"
    local prompt="$1" default="${2:-N}"
    local default_label="y/N"
    [[ "$default" =~ ^[Yy]$ ]] && default_label="Y/n"

    if [[ "$INTERACTIVE" == false ]]; then
        [[ "$default" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
        return
    fi
    local response
    tty_read "$(echo -e "${BOLD}? ${prompt}${NC} [${YELLOW}${default_label}${NC}]: ")" response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
}

set_env() {
    # set_env KEY VALUE -- write KEY=value to $ENV_FILE.
    #
    # The wizard builds .env from scratch (write_env_header / set_env_section
    # / set_env are the only writers). That makes the file far easier to
    # read than a copy-of-.env.example with values surgically replaced
    # inside long instructional comment blocks. Operators who want the
    # full reference can read .env.example -- it's still in the repo.
    #
    # If KEY= already exists in the file (re-call within the same wizard
    # run, defensive), the value is replaced in-place rather than
    # appended a second time.
    local key="$1" value="$2" escaped
    escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
    if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
        sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
}

# write_env_header -- write the top-of-.env preamble. Stdout, so the
# caller redirects it: `write_env_header > "$ENV_FILE"`.
write_env_header() {
    cat <<EOF
# =============================================================================
# CS-Traefik -- generated by install.sh wizard
# =============================================================================
# Generated:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Hostname:     $(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "?")
#
# This file is intentionally MINIMAL: it contains ONLY the keys the
# wizard set. Every other knob keeps the compose-baked default. To
# override a default, look up the key (and its documented semantics)
# in .env.example and add a line below the relevant section.
#
# Re-run the wizard via:
#     sudo ./install.sh --reconfigure
#     sudo ./traefik.sh setup
# =============================================================================

EOF
}

# set_env_section "Title"  -- emit a section banner to $ENV_FILE so the
# generated file groups related keys (matches the layout the operator
# is used to from .env.example).
set_env_section() {
    local title="$1"
    {
        printf '\n'
        printf '# -----------------------------------------------------------------------------\n'
        printf '# %s\n' "$title"
        printf '# -----------------------------------------------------------------------------\n'
    } >> "$ENV_FILE"
}

# set_env_comment_block MARKER LINE [LINE ...]
# Append (or replace) a marker-bracketed comment block at the END of
# $ENV_FILE. Used to persist generated plaintext credentials so the
# operator can recover them if they miss the wizard output. Replaces
# any prior block with the same marker -- a re-run of the wizard does
# not stack duplicates.
set_env_comment_block() {
    local marker="$1"; shift
    local begin="# === ${marker}-BEGIN ==="
    local end="# === ${marker}-END ==="

    # If a prior block exists, drop it first.
    if grep -qF "$begin" "$ENV_FILE"; then
        sed -i.bak "/^${begin}$/,/^${end}$/d" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
        # Trim trailing blank line left by sed delete.
        if [[ -s "$ENV_FILE" ]] && [[ -z "$(tail -1 "$ENV_FILE")" ]]; then
            sed -i.bak '$d' "$ENV_FILE"
            rm -f "$ENV_FILE.bak"
        fi
    fi

    {
        printf '\n%s\n' "$begin"
        for line in "$@"; do
            printf '# %s\n' "$line"
        done
        printf '%s\n' "$end"
    } >> "$ENV_FILE"
}

# detect_host_timezone -- best-effort host timezone detection.
#
# Tries (in order):
#   1. /etc/timezone               -- Debian / Ubuntu < 24 plain text
#   2. timedatectl show -p Timezone  -- modern systemd
#   3. readlink -f /etc/localtime  -- Ubuntu 24.04 / RHEL family (symlink
#                                     to /usr/share/zoneinfo/Region/City)
#   4. fallback Etc/UTC
#
# We avoid `cat /etc/timezone` as the only path because Ubuntu 24.04
# stopped shipping that file in default installs -- it's now derived
# from the /etc/localtime symlink. The legacy default would always
# return "Etc/UTC" on a freshly installed Ubuntu 24.04 box, which is
# what the user just hit.
detect_host_timezone() {
    local tz
    if [[ -f /etc/timezone ]] && [[ -s /etc/timezone ]]; then
        tz=$(tr -d '[:space:]' < /etc/timezone)
        [[ -n "$tz" ]] && { echo "$tz"; return; }
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
        [[ -n "$tz" ]] && { echo "$tz"; return; }
    fi
    if [[ -L /etc/localtime ]]; then
        # /etc/localtime -> /usr/share/zoneinfo/Europe/Berlin
        tz=$(readlink -f /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')
        [[ -n "$tz" ]] && { echo "$tz"; return; }
    fi
    echo "Etc/UTC"
}

generate_password() {
    # 24-char alphanumeric + safe symbol (no shell-meta to avoid quoting bugs)
    local part1 part2 sym
    part1=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 12)
    part2=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 11)
    local symbols='@#%-_.'
    sym=${symbols:$((RANDOM % ${#symbols})):1}
    echo "${part1}${sym}${part2}"
}

generate_basic_auth() {
    # generate_basic_auth user password  -> "user:bcrypt-hash" (Compose-escaped)
    local user="$1" pass="$2" hash

    # Try host htpasswd first
    if command -v htpasswd >/dev/null 2>&1; then
        hash=$(htpasswd -nbB "$user" "$pass" 2>/dev/null | head -1)
        echo "${hash//\$/\$\$}"
        return
    fi
    # Fallback: container with httpd-tools
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        hash=$(docker run --rm httpd:alpine htpasswd -nbB "$user" "$pass" 2>/dev/null | head -1)
        echo "${hash//\$/\$\$}"
        return
    fi
    # Last resort: try installing apache2-utils
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y -qq apache2-utils 2>/dev/null || true
        if command -v htpasswd >/dev/null 2>&1; then
            hash=$(htpasswd -nbB "$user" "$pass" 2>/dev/null | head -1)
            echo "${hash//\$/\$\$}"
            return
        fi
    fi
    print_error "Cannot generate bcrypt hash: neither htpasswd nor Docker available."
    exit 1
}

run_wizard() {
    if [[ ! -f "$ENV_EXAMPLE" ]]; then
        print_error ".env.example missing at $ENV_EXAMPLE"
        exit 1
    fi

    # Decide whether to re-run the wizard
    if [[ -f "$ENV_FILE" ]]; then
        if [[ "$RECONFIGURE" == true ]]; then
            print_warning ".env exists -- backing up before overwrite (--reconfigure)."
            local backup="$ENV_FILE.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$ENV_FILE" "$backup"
            print_info "Backup: $backup"
        elif [[ "$INTERACTIVE" == false ]]; then
            print_info ".env already exists; skipping wizard (use --reconfigure to overwrite)."
            return 0
        else
            print_warning ".env already exists at $ENV_FILE"
            if [[ "$(ask_yes_no "Re-run the wizard and overwrite?" N)" == "no" ]]; then
                print_info "Keeping existing .env."
                return 0
            fi
            local backup="$ENV_FILE.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$ENV_FILE" "$backup"
            print_info "Backup: $backup"
        fi
    fi

    # Build .env from scratch with just the keys the wizard sets.
    # The full reference (every key, every default, every comment block)
    # remains in $ENV_EXAMPLE -- the operator reads that, then adds
    # overrides to the freshly-generated .env section-by-section.
    write_env_header > "$ENV_FILE"
    print_success "Initialised $ENV_FILE with wizard-managed values only."

    # Defaults derived from the host
    local default_tz default_host default_domain
    default_tz=$(detect_host_timezone)
    default_host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
    default_domain="${default_host#*.}"
    [[ "$default_domain" == "$default_host" ]] && default_domain="example.com"

    # ---- Stack identity ----
    print_section "Stack identity"
    set_env_section "Stack identity"
    local stack_name network_name time_zone data_dir
    stack_name=$(ask "Compose project name (lowercase)" "edgeproxy")
    network_name=$(ask "Public network name (legacy default: EDGEPROXY)" "EDGEPROXY")
    time_zone=$(ask "Timezone (IANA name)" "$default_tz")
    # Default `./data` keeps runtime state under the install dir but in
    # a clearly-separated, gitignored subdirectory. Override to an
    # absolute path if you want state on a separate disk / volume.
    # Never suggest the install dir itself (would mix repo files with
    # runtime state).
    #
    # Disk-layout sniff: if /var/lib/docker is on a different (larger)
    # filesystem than the install dir, print a one-line hint. Common
    # BG topology: /var/lib/docker on a dedicated big volume (for
    # images + named volumes), /opt on OS root (smaller). Heavy state
    # (Prometheus TSDB, Loki chunks) can fill OS root over weeks --
    # the operator can override DATA_DIRECTORY here if relevant.
    if command -v df >/dev/null 2>&1 && [[ -d /var/lib/docker ]]; then
        local install_fs docker_fs install_avail docker_avail
        install_fs=$(df --output=source "$INSTALL_DIR" 2>/dev/null | tail -1)
        docker_fs=$(df --output=source /var/lib/docker 2>/dev/null | tail -1)
        if [[ -n "$install_fs" && -n "$docker_fs" && "$install_fs" != "$docker_fs" ]]; then
            install_avail=$(df --output=avail -BG "$INSTALL_DIR" 2>/dev/null | tail -1 | tr -d 'G ')
            docker_avail=$(df --output=avail -BG /var/lib/docker 2>/dev/null | tail -1 | tr -d 'G ')
            if [[ -n "$install_avail" && -n "$docker_avail" ]] && (( docker_avail > install_avail )); then
                echo
                print_warning "Disk-layout note: /var/lib/docker is on a separate volume."
                print_warning "    Install dir ($INSTALL_DIR) free space: ${install_avail} GB"
                print_warning "    /var/lib/docker free space:            ${docker_avail} GB"
                print_warning ""
                print_warning "Heavy runtime state (Prometheus TSDB, Loki chunks) can grow to"
                print_warning "tens of GB over weeks. The default './data' lands on the install"
                print_warning "dir's filesystem -- if that is constrained, consider overriding"
                print_warning "to a path on the larger volume. See docs/installation.md ->"
                print_warning "'Disk layout considerations' for the typical patterns."
                echo
            fi
        fi
    fi
    data_dir=$(ask "Data directory (relative to install dir, OR absolute path for separate disk)" "./data")

    set_env STACK_NAME      "$stack_name"
    set_env NETWORK_NAME    "$network_name"
    set_env TIME_ZONE       "$time_zone"
    set_env DATA_DIRECTORY  "$data_dir"

    # ---- Profiles ----
    # Default = core-only. Monitoring and auto-update are opt-in -- this
    # matches "minimum surface, opt into more" rather than "ship the full
    # stack and hope nothing breaks". Same logic as the legacy stack.
    print_section "Profiles (opt-in features)"
    set_env_section "Profiles"
    cat <<EOF
Available profiles:
    monitoring   -> Prometheus + Grafana + Loki + Promtail + exporters
                    Reachable on the api entrypoint (localhost-only by
                    default), at /grafana, /prometheus, /alertmanager.
    auto-update  -> Watchtower keeps images current on a weekly cron.

Default = core only (just Traefik). Skip both for the leanest setup.
EOF
    echo
    local profiles=""
    if [[ "$(ask_yes_no "Enable monitoring profile?" N)" == "yes" ]]; then
        profiles="monitoring"
    fi
    if [[ "$(ask_yes_no "Enable auto-update profile?" N)" == "yes" ]]; then
        [[ -n "$profiles" ]] && profiles+=","
        profiles+="auto-update"
    fi
    set_env COMPOSE_PROFILES "$profiles"

    # ---- Admin access (api entrypoint) ----
    print_section "Admin access (Traefik dashboard + monitoring UIs)"
    set_env_section "Admin access"
    cat <<EOF
Admin UIs are reached through the dedicated 'api' entrypoint, NEVER on
port 443 by default. Three modes:

  1) Localhost only -- bind 127.0.0.1:9090 (DEFAULT, most secure).
     Reach via SSH-tunnel:
       ssh -L 9090:127.0.0.1:9090 user@server
       open http://127.0.0.1:9090/dashboard/
  2) LAN-accessible -- bind 0.0.0.0:9090 (BasicAuth-only, no TLS).
     OK on trusted networks; not for public internet.
  3) Public FQDN over HTTPS -- additionally route /dashboard /grafana
     /prometheus /alertmanager on a dedicated FQDN like
     admin.bauer-group.com (BasicAuth + IP whitelist + Let's Encrypt TLS).

EOF

    local mode_choice="1"
    if [[ "$INTERACTIVE" == true ]]; then
        tty_read "${BOLD}? Mode${NC} [1=localhost / 2=LAN / 3=public FQDN] [${YELLOW}1${NC}]: " mode_choice
        mode_choice=${mode_choice:-1}
    fi

    local api_host="" api_base_url="http://localhost:9090"
    case "$mode_choice" in
        2)
            set_env API_BIND      "0.0.0.0"
            set_env API_BIND_V6   "::"
            set_env API_HOST      ""
            set_env API_BASE_URL  "http://localhost:9090"
            ;;
        3)
            api_host=$(ask "Admin FQDN (must host NO application)" "admin.${default_domain}")
            set_env API_BIND      "127.0.0.1"
            set_env API_BIND_V6   "::1"
            set_env API_HOST      "$api_host"
            set_env API_BASE_URL  "https://${api_host}"
            api_base_url="https://${api_host}"
            ;;
        *)
            set_env API_BIND      "127.0.0.1"
            set_env API_BIND_V6   "::1"
            set_env API_HOST      ""
            set_env API_BASE_URL  "http://localhost:9090"
            ;;
    esac

    set_env API_PORT "9090"

    local api_whitelist
    api_whitelist=$(ask "IP whitelist (comma-separated CIDRs)" \
        "127.0.0.1/32, ::1/128, 192.168.0.0/16, 10.0.0.0/8")
    set_env API_WHITELIST "$api_whitelist"

    local admin_user admin_pass admin_pass_display="" auth_string
    admin_user=$(ask "Admin username (BasicAuth)" "admin")
    if [[ "$INTERACTIVE" == true ]]; then
        echo
        if [[ "$(ask_yes_no "Generate a random password?" Y)" == "yes" ]]; then
            admin_pass=$(generate_password)
            print_warning "Generated admin password: ${BOLD}${admin_pass}${NC}"
            print_warning "(this is the LAST time you'll see it -- save it now)"
        else
            tty_read_silent "${BOLD}? Admin password${NC}: " admin_pass
        fi
    else
        admin_pass=$(generate_password)
    fi

    print_info "Generating bcrypt hash ..."
    auth_string=$(generate_basic_auth "$admin_user" "$admin_pass")
    set_env API_USERS "$auth_string"
    admin_pass_display="$admin_pass"
    # Persist the plaintext alongside API_USERS so the operator can recover
    # it if they lose the wizard output. Comment-form so it never collides
    # with API_USERS evaluation. Marker prefix lets reconfigure runs replace
    # the previous block instead of stacking comments on top of each other.
    set_env_comment_block "ADMIN_PLAINTEXT" \
        "Generated by install.sh wizard at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "Admin user:     $admin_user" \
        "Admin password: $admin_pass" \
        "Stored here for operator recovery only -- the live credential is" \
        "the bcrypt hash in API_USERS above. Delete this block once saved" \
        "in your password manager."

    # ---- Let's Encrypt ----
    print_section "Let's Encrypt"
    set_env_section "Let's Encrypt"
    local le_email
    le_email=$(ask "ACME contact email" "admin@${default_domain}")
    set_env LETSENCRYPT_EMAIL "$le_email"

    if [[ "$(ask_yes_no "Use Let's Encrypt staging (recommended for first run)?" N)" == "yes" ]]; then
        set_env LETSENCRYPT_CA "https://acme-staging-v02.api.letsencrypt.org/directory"
    else
        set_env LETSENCRYPT_CA "https://acme-v02.api.letsencrypt.org/directory"
    fi

    # ---- Monitoring credentials (if profile selected) ----
    local grafana_pass_display="" grafana_user="admin"
    if [[ ",$profiles," == *",monitoring,"* ]]; then
        print_section "Monitoring (Grafana admin credentials)"
        set_env_section "Monitoring (Grafana login)"
        echo "Grafana, Prometheus, and Alertmanager all live behind the api"
        echo "entrypoint at /grafana /prometheus /alertmanager. They share the"
        echo "same BasicAuth + IP whitelist as the Traefik dashboard."
        echo "Grafana additionally has its OWN login (the credentials below)."
        echo
        local grafana_pass
        grafana_user=$(ask "Grafana admin username" "admin")
        set_env GRAFANA_ADMIN_USER "$grafana_user"

        if [[ "$INTERACTIVE" == true ]] \
            && [[ "$(ask_yes_no "Generate a random Grafana admin password?" Y)" == "yes" ]]; then
            grafana_pass=$(generate_password)
            print_warning "Generated Grafana password: ${BOLD}${grafana_pass}${NC}"
        elif [[ "$INTERACTIVE" == true ]]; then
            tty_read_silent "${BOLD}? Grafana admin password${NC}: " grafana_pass
        else
            grafana_pass=$(generate_password)
        fi
        set_env GRAFANA_ADMIN_PASSWORD "$grafana_pass"
        grafana_pass_display="$grafana_pass"
        set_env_comment_block "GRAFANA_PLAINTEXT" \
            "Grafana login (separate from API_USERS BasicAuth)" \
            "User:     $grafana_user" \
            "Password: $grafana_pass" \
            "Live credential is GRAFANA_ADMIN_PASSWORD above. Delete this" \
            "block once saved in your password manager."
    fi

    # Lock down .env
    chmod 600 "$ENV_FILE"

    # ---- Summary ----
    print_section "Wizard complete"
    echo
    echo "  Configuration: $ENV_FILE"
    echo "  Permissions:   600 (owner read/write only)"
    echo
    echo "  Admin access:"
    case "$mode_choice" in
        2) echo "    Mode: LAN-accessible at  http://<host>:9090/dashboard/" ;;
        3) echo "    Mode: Public FQDN at     https://${api_host}/dashboard/" ;;
        *) echo "    Mode: Localhost only     ssh -L 9090:127.0.0.1:9090 user@host" ;;
    esac
    if [[ -n "$admin_pass_display" ]] || [[ -n "$grafana_pass_display" ]]; then
        echo
        echo -e "  ${YELLOW}${BOLD}Generated credentials (save these now!):${NC}"
        [[ -n "$admin_pass_display"   ]] && echo -e "    Admin (BasicAuth): ${admin_user} / ${BOLD}${admin_pass_display}${NC}"
        [[ -n "$grafana_pass_display" ]] && echo -e "    Grafana login:     ${grafana_user} / ${BOLD}${grafana_pass_display}${NC}"
    fi
    echo
}

# -----------------------------------------------------------------------------
# Stack start (LOCAL_MODE only)
# -----------------------------------------------------------------------------
start_stack() {
    if [[ "$START_STACK" == false ]]; then
        print_info "Skipping stack start."
        return 0
    fi
    if [[ ! -x "$PROJECT_ROOT/traefik.sh" ]]; then
        print_warning "traefik.sh not executable -- skipping start. Run manually:"
        echo "    sudo $PROJECT_ROOT/traefik.sh start"
        return 0
    fi

    print_section "Starting the stack"
    "$PROJECT_ROOT/traefik.sh" start
}

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------
print_summary() {
    local ip
    ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<host-ip>")

    echo
    echo -e "${GREEN}==============================================================================="
    echo -e "                   CS-Traefik installation complete"
    echo -e "===============================================================================${NC}"
    echo
    echo "  Install path:       $PROJECT_ROOT"
    echo "  Configuration:      $PROJECT_ROOT/.env"
    echo "  Management script:  $PROJECT_ROOT/traefik.sh"
    echo
    echo -e "  ${CYAN}Quick reference${NC}"
    echo "    sudo $PROJECT_ROOT/traefik.sh start | stop | restart | status | logs"
    echo "    sudo $PROJECT_ROOT/traefik.sh update    -- pull newer images"
    echo "    sudo $PROJECT_ROOT/traefik.sh deploy    -- pull newer scripts from git"
    echo "    sudo $PROJECT_ROOT/install.sh --reconfigure  -- re-run the wizard"
    echo "    sudo $PROJECT_ROOT/traefik.sh help"
    echo
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        local dashboard_host grafana_host profiles
        dashboard_host=$(grep -E '^DASHBOARD_HOST=' "$PROJECT_ROOT/.env" | cut -d'=' -f2- || true)
        grafana_host=$(grep -E '^GRAFANA_HOST=' "$PROJECT_ROOT/.env" | cut -d'=' -f2- || true)
        profiles=$(grep -E '^COMPOSE_PROFILES=' "$PROJECT_ROOT/.env" | cut -d'=' -f2- || true)

        echo -e "  ${CYAN}Endpoints${NC}"
        [[ -n "$dashboard_host" ]] && echo "    Dashboard:          https://$dashboard_host"
        if [[ ",$profiles," == *",monitoring,"* ]] && [[ -n "$grafana_host" ]]; then
            echo "    Grafana:            https://$grafana_host"
        fi
        echo "    Host IP:            $ip"
        echo
    fi
    echo -e "  ${CYAN}Documentation${NC}"
    echo "    $PROJECT_ROOT/README.md"
    echo
}

# =============================================================================
# Upgrade flow: legacy v2 stack -> CS-Traefik v3
# =============================================================================
# Designed for batch rollout to many hosts. Phases are atomic and reversible
# up to the rename step:
#
#   1. Detect    (read-only)
#   2. Confirm   (skipped with --auto)
#   3. Stop      (compose down -- volumes preserved, networks removed)
#   4. Backup    (mv old dir -> <old>-v2-backup-<TS>; instant + atomic)
#   5. Install   (clone v3 to old path)
#   6. Migrate   (read old .env values -> write new .env)
#   7. Migrate   (ACME certs via traefik.sh migrate-acme)
#   8. Start     (traefik.sh start with COMPOSE_PROFILES=monitoring)
#   9. Verify    (Traefik healthy)
# =============================================================================

# State carried between phases (set by detect_v2_stack / parse_api_host)
V2_SOURCE_DIR=""
V2_BACKUP_DIR=""
V2_DETECTED_PROJECTS=""
V2_API_BIND=""
V2_API_BIND_V6=""
V2_API_HOSTNAME=""
declare -A V2_OLD_ENV   # parsed key=value pairs from old .env

upgrade_run_or_dry() {
    if [[ "$DRY_RUN" == true ]]; then
        echo "    [dry-run] $*"
    else
        eval "$@"
    fi
}

# Phase 1 -- Detection -------------------------------------------------------
detect_v2_stack() {
    local dir="$1"
    print_section "Phase 1: Detect v2 stack at $dir"

    if [[ ! -f "$dir/docker-compose.yml" ]]; then
        print_error "No docker-compose.yml at $dir -- nothing to upgrade."
        exit 2
    fi

    # Quick sanity: does the compose file mention traefik:v2.* ?
    if grep -qE "image:[[:space:]]*traefik:v2" "$dir/docker-compose.yml"; then
        print_success "v2 Traefik stack detected at $dir"
    elif grep -qE "image:[[:space:]]*traefik:v3" "$dir/docker-compose.yml"; then
        print_warning "Compose file at $dir already references traefik:v3."
        print_warning "Looks like the upgrade may have already happened. Aborting."
        exit 0
    else
        print_warning "Compose file at $dir does not reference traefik:v2 or v3 explicitly."
        print_warning "Image references found:"
        grep -E "image:" "$dir/docker-compose.yml" | head -3 | sed 's/^/    /'
        if [[ "$AUTO_UPGRADE" != true ]]; then
            ask_yes_no "Continue anyway?" "n" || exit 0
        fi
    fi

    # Parse old .env (if exists)
    if [[ -f "$dir/.env" ]]; then
        # Read each KEY=VALUE pair (unquote, ignore comments + blanks)
        while IFS='=' read -r key val; do
            [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
            # Strip leading/trailing whitespace + quotes from value
            val="${val%\"}"; val="${val#\"}"
            val="${val%\'}"; val="${val#\'}"
            V2_OLD_ENV["$key"]="$val"
        done < <(grep -E '^[A-Z_]+=' "$dir/.env" 2>/dev/null || true)
        print_info "Parsed $(echo "${!V2_OLD_ENV[@]}" | wc -w) variables from old .env"
    else
        print_warning "No .env at $dir -- new install will use v3 defaults."
    fi
}

detect_running_projects() {
    print_section "Phase 1b: Auto-detect running v2 compose projects"
    # Find compose projects that have a container with image traefik:v2.*
    local projects
    projects=$(docker ps -a --format '{{.Image}}|{{.Label "com.docker.compose.project"}}' 2>/dev/null \
              | awk -F'|' '$1 ~ /^traefik:v2/ && $2 != "" {print $2}' | sort -u || true)

    if [[ -n "$projects" ]]; then
        V2_DETECTED_PROJECTS="$projects"
        print_info "Compose projects with v2 Traefik containers:"
        echo "$projects" | sed 's/^/    /'
    else
        print_info "No running v2 stack detected (already stopped, or never running)."
    fi
}

parse_api_host() {
    # Pipe-separated list of IPv4 / IPv6 / hostnames -> separate buckets.
    # Example input:  "192.168.2.96|srv-host.dmz.example|2001:db8::1"
    local input="$1"
    V2_API_BIND=""; V2_API_BIND_V6=""; V2_API_HOSTNAME=""
    [[ -z "$input" ]] && return

    local IFS_BAK="$IFS"
    IFS='|'
    set -f
    local parts=( $input )
    set +f
    IFS="$IFS_BAK"

    for raw in "${parts[@]}"; do
        local part="${raw// /}"
        [[ -z "$part" ]] && continue
        if [[ "$part" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            [[ -z "$V2_API_BIND" ]] && V2_API_BIND="$part"
        elif [[ "$part" =~ : ]] && [[ ! "$part" =~ \. ]]; then
            [[ -z "$V2_API_BIND_V6" ]] && V2_API_BIND_V6="$part"
        else
            [[ -z "$V2_API_HOSTNAME" ]] && V2_API_HOSTNAME="$part"
        fi
    done
}

# Phase 2 -- Confirm ---------------------------------------------------------
print_upgrade_plan() {
    local source="$1" backup="$2"
    print_section "Phase 2: Upgrade plan"

    cat <<EOF
The following will happen:

  Source v2 stack         : $source
  Backup destination      : $backup
                            (atomic rename; volumes preserved separately)
  Target v3 install       : $INSTALL_DIR
  Compose profiles        : monitoring (upgrade default)

Detected v2 compose projects to stop:
$(if [[ -n "$V2_DETECTED_PROJECTS" ]]; then echo "$V2_DETECTED_PROJECTS" | sed 's/^/      /'; else echo "      (none running)"; fi)

Old networks to remove (volumes are preserved):
      EDGEPROXY, EDGEPROXY_INTERNAL, plus any matching by name

Settings migrated from old .env:
      API_USERS              -> kept verbatim (already bcrypt-escaped)
      API_WHITELIST          -> kept verbatim (preserves your LAN CIDRs)
      GRAFANA_ADMIN_PASSWORD -> kept verbatim
      API_PORT               -> only if non-default (default v3: 9090)
      LETSENCRYPT_EMAIL      -> kept verbatim
      API_HOST               -> SPLIT:
                                   IPv4 part   -> API_BIND  (binds 0.0.0.0
                                                  to preserve v2 all-interface
                                                  + loopback access)
                                   IPv6 part   -> API_BIND_V6 (likewise ::)
                                   hostname    -> noted but NOT migrated
                                                  (v3 API_HOST is for mode-3
                                                  public-FQDN-with-LE only)
      DATA_DIRECTORY         -> ./data (v3 default)
      COMPOSE_PROFILES       -> monitoring

ACME certificates:
      Source : <backup>/configuration/traefik/certificates/dynamic/letsencrypt.json
      Target : <install>/data/traefik/letsencrypt/letsencrypt-tls.json
                              (matches v2's TLS-ALPN-01 challenge type)

Volumes:
      Existing Docker named volumes are NOT touched.

Recovery:
      If anything goes wrong, the v2 stack is at $backup --
      manually rename it back to restore.

EOF
}

# Phase 3 -- Stop ------------------------------------------------------------
stop_v2_stack() {
    local dir="$1"
    print_section "Phase 3: Stop v2 stack"

    # Try detected projects first
    if [[ -n "$V2_DETECTED_PROJECTS" ]]; then
        while IFS= read -r project; do
            print_info "compose down (project=$project)"
            upgrade_run_or_dry "docker compose -f '$dir/docker-compose.yml' --project-name '$project' down --remove-orphans 2>&1 || true"
        done <<< "$V2_DETECTED_PROJECTS"
    fi

    # Belt-and-suspenders: try common project names too. Errors ignored
    # (project may not exist).
    local stack_name="${V2_OLD_ENV[STACK_NAME]:-edgeproxy}"
    local fallback_names=( "$stack_name" "$(echo "$stack_name" | tr '[:upper:]' '[:lower:]')" "edgeproxy" "$(basename "$dir")" "$(hostname)" "default" )
    # Dedup
    local seen=" "
    for name in "${fallback_names[@]}"; do
        [[ -z "$name" || "$seen" == *" $name "* ]] && continue
        seen="$seen$name "
        upgrade_run_or_dry "docker compose -f '$dir/docker-compose.yml' --project-name '$name' down --remove-orphans 2>/dev/null || true"
    done

    print_success "v2 stack stopped (or was already)."
}

remove_v2_networks() {
    print_section "Phase 3b: Remove legacy networks (volumes preserved)"
    local nets=( "${V2_OLD_ENV[NETWORK_NAME]:-EDGEPROXY}" "${V2_OLD_ENV[NETWORK_NAME]:-EDGEPROXY}_INTERNAL" "EDGEPROXY" "EDGEPROXY_INTERNAL" "edgeproxy" "edgeproxy_internal" )
    local seen=" "
    for net in "${nets[@]}"; do
        [[ -z "$net" || "$seen" == *" $net "* ]] && continue
        seen="$seen$net "
        if docker network inspect "$net" >/dev/null 2>&1; then
            print_info "docker network rm $net"
            upgrade_run_or_dry "docker network rm '$net' 2>/dev/null || true"
        fi
    done
    print_success "Legacy networks removed (where present)."
}

# Phase 4 -- Backup ----------------------------------------------------------
backup_v2_dir() {
    local source="$1" backup="$2"
    print_section "Phase 4: Atomic rename to backup"
    if [[ -d "$source" ]]; then
        upgrade_run_or_dry "mv '$source' '$backup'"
        print_success "$source -> $backup"
    fi
}

# Phase 6 -- Migrate settings ------------------------------------------------
generate_env_with_migration() {
    local backup_dir="$1"
    local new_env="$INSTALL_DIR/.env"
    local example="$INSTALL_DIR/.env.example"
    print_section "Phase 6: Migrate .env settings"

    if [[ "$DRY_RUN" == true ]]; then
        echo "    [dry-run] would write a minimal .env with the migrated v2 values"
        return 0
    fi

    # Write fresh, minimal .env -- same approach as the wizard. The
    # full reference stays in .env.example.
    local saved_env_file="$ENV_FILE"
    ENV_FILE="$new_env"
    write_env_header > "$ENV_FILE"

    # ---- Profiles (upgrade default = monitoring) --------------------------
    set_env_section "Profiles"
    set_env COMPOSE_PROFILES "monitoring"
    print_info "COMPOSE_PROFILES set to: monitoring (upgrade default)"

    # ---- Admin access ----------------------------------------------------
    set_env_section "Admin access"

    # API_USERS (bcrypt hash, contains $$ -- write verbatim through set_env;
    # set_env's sed escapes $ as part of [\\&|], but the hash uses $$ which
    # is intentional Compose escaping -- those bytes must survive untouched).
    if [[ -n "${V2_OLD_ENV[API_USERS]:-}" ]]; then
        # Bypass set_env's sed escaping: write directly. Value is already
        # $$ -escaped for Compose; appending it raw preserves that.
        printf 'API_USERS=%s\n' "${V2_OLD_ENV[API_USERS]}" >> "$ENV_FILE"
        print_info "API_USERS migrated (bcrypt hash preserved)"
    fi

    if [[ -n "${V2_OLD_ENV[API_WHITELIST]:-}" ]]; then
        set_env API_WHITELIST "${V2_OLD_ENV[API_WHITELIST]}"
        print_info "API_WHITELIST migrated: ${V2_OLD_ENV[API_WHITELIST]}"
    fi

    if [[ -n "${V2_OLD_ENV[API_PORT]:-}" && "${V2_OLD_ENV[API_PORT]}" != "9090" ]]; then
        set_env API_PORT "${V2_OLD_ENV[API_PORT]}"
        print_info "API_PORT migrated: ${V2_OLD_ENV[API_PORT]} (non-default)"
    fi

    # API_HOST -> API_BIND / API_BIND_V6 (v2 was effectively all-interfaces;
    # preserve same behaviour by binding 0.0.0.0 / ::)
    if [[ -n "${V2_OLD_ENV[API_HOST]:-}" ]]; then
        parse_api_host "${V2_OLD_ENV[API_HOST]}"
        if [[ -n "$V2_API_BIND" || -n "$V2_API_BIND_V6" ]]; then
            set_env API_BIND    "0.0.0.0"
            set_env API_BIND_V6 "::"
            print_info "API_BIND set to 0.0.0.0 / :: (preserves v2 all-interfaces + loopback)"
            [[ -n "$V2_API_BIND" ]]     && print_info "  detected v4 IP from old API_HOST: $V2_API_BIND"
            [[ -n "$V2_API_BIND_V6" ]]  && print_info "  detected v6 IP from old API_HOST: $V2_API_BIND_V6"
            [[ -n "$V2_API_HOSTNAME" ]] && print_warning "  hostname '$V2_API_HOSTNAME' was in old API_HOST -- NOT migrated to v3 API_HOST (mode-3 needs a real public FQDN with LE-issuable cert)"
        fi
    fi

    # ---- Let's Encrypt ----------------------------------------------------
    if [[ -n "${V2_OLD_ENV[LETSENCRYPT_EMAIL]:-}" && "${V2_OLD_ENV[LETSENCRYPT_EMAIL]}" != "info@bauer-group.com" ]]; then
        set_env_section "Let's Encrypt"
        set_env LETSENCRYPT_EMAIL "${V2_OLD_ENV[LETSENCRYPT_EMAIL]}"
        print_info "LETSENCRYPT_EMAIL migrated: ${V2_OLD_ENV[LETSENCRYPT_EMAIL]}"
    fi

    # ---- Monitoring credentials ------------------------------------------
    if [[ -n "${V2_OLD_ENV[GRAFANA_ADMIN_PASSWORD]:-}" ]]; then
        local pwd="${V2_OLD_ENV[GRAFANA_ADMIN_PASSWORD]}"
        pwd="${pwd#\"}"; pwd="${pwd%\"}"; pwd="${pwd#\'}"; pwd="${pwd%\'}"
        set_env_section "Monitoring (Grafana login)"
        set_env GRAFANA_ADMIN_PASSWORD "$pwd"
        print_info "GRAFANA_ADMIN_PASSWORD migrated"
    fi

    # Restore caller's ENV_FILE (defensive; upgrade flow may continue).
    ENV_FILE="$saved_env_file"

    chmod 600 "$new_env"
    print_success "Migrated .env written: $new_env"
}

# Phase 7 -- Migrate ACME ----------------------------------------------------
migrate_acme_from_backup() {
    local backup_dir="$1"
    local source_acme="$backup_dir/configuration/traefik/certificates/dynamic/letsencrypt.json"
    print_section "Phase 7: Migrate ACME certificates"

    if [[ ! -f "$source_acme" ]]; then
        print_warning "No ACME storage at $source_acme."
        print_warning "Skipping cert migration -- new stack will issue fresh certs"
        print_warning "on first request (potentially burning Let's Encrypt rate-limit budget)."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo "    [dry-run] traefik.sh migrate-acme --source '$source_acme'"
        return 0
    fi

    cd "$INSTALL_DIR"
    if ! bash ./traefik.sh migrate-acme --source "$source_acme" 2>&1; then
        print_warning "ACME migration command exited non-zero."
        print_warning "Check the message above and run manually if needed:"
        print_warning "  sudo $INSTALL_DIR/traefik.sh migrate-acme --source '$source_acme'"
    fi
}

# Phase 8/9 -- Start + verify ------------------------------------------------
verify_upgrade() {
    print_section "Phase 9: Verify Traefik healthy"
    if [[ "$DRY_RUN" == true ]]; then
        echo "    [dry-run] would wait for Traefik healthcheck"
        return 0
    fi
    local stack_name max_wait elapsed
    stack_name=$(grep -E '^STACK_NAME=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2- || echo "edgeproxy")
    max_wait=120
    elapsed=0
    while (( elapsed < max_wait )); do
        local state
        state=$(docker inspect -f '{{.State.Health.Status}}' "${stack_name}-traefik" 2>/dev/null || echo "missing")
        case "$state" in
            healthy)  print_success "Traefik healthy after ${elapsed}s."; return 0 ;;
            unhealthy) print_error "Traefik reports unhealthy. Check: docker logs ${stack_name}-traefik"; return 1 ;;
            missing)  print_warning "Container ${stack_name}-traefik not running yet..." ;;
        esac
        sleep 5
        elapsed=$((elapsed + 5))
    done
    print_warning "Traefik did not reach healthy state in ${max_wait}s."
    print_warning "Check: docker compose -f $INSTALL_DIR/docker-compose.yml logs traefik"
    return 1
}

print_upgrade_summary() {
    local backup_dir="$1"
    print_section "Upgrade complete"
    cat <<EOF

  Backup of old v2 stack: $backup_dir
                          (rename it back to $V2_SOURCE_DIR if you need to roll back)
  New v3 install:         $INSTALL_DIR
  Profiles active:        monitoring

Next steps:
  1. Verify routing -- hit each migrated host:
       curl -vI https://your-host/
  2. Watch ACME renewal logs over the next few days:
       sudo $INSTALL_DIR/traefik.sh logs traefik | grep -i acme
  3. Once you have confirmed the v3 stack is healthy and certs renew
     correctly (typically 30 days before each cert's notAfter), you
     may delete the backup:
       sudo rm -rf $backup_dir

EOF
}

# Top-level orchestrator -----------------------------------------------------
upgrade_from_v2() {
    print_banner
    require_root
    check_os
    ensure_basic_tools
    ensure_docker

    local source="${UPGRADE_SOURCE:-$INSTALL_DIR}"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    V2_SOURCE_DIR="$source"
    V2_BACKUP_DIR="${source}-v2-backup-${timestamp}"

    detect_v2_stack "$source"
    detect_running_projects

    print_upgrade_plan "$source" "$V2_BACKUP_DIR"

    if [[ "$AUTO_UPGRADE" != true && "$DRY_RUN" != true ]]; then
        if ! ask_yes_no "Proceed with upgrade?" "y"; then
            print_info "Aborted."
            exit 0
        fi
    fi

    if [[ "$DRY_RUN" == true ]]; then
        print_info "DRY-RUN: showing planned operations only."
    fi

    stop_v2_stack "$source"
    remove_v2_networks
    backup_v2_dir "$source" "$V2_BACKUP_DIR"

    if [[ "$DRY_RUN" != true ]]; then
        # Phase 5: install v3 (clones if not already at INSTALL_DIR; if SCRIPT_DIR
        # is the freshly-bootstrapped /tmp install.sh, this is the right call).
        clone_or_update_repo
    fi

    generate_env_with_migration "$V2_BACKUP_DIR"
    migrate_acme_from_backup "$V2_BACKUP_DIR"

    if [[ "$DRY_RUN" == true ]]; then
        print_section "Dry-run complete"
        print_info "No changes made. Re-run without --dry-run to execute."
        return 0
    fi

    print_section "Phase 8: Start new stack"
    cd "$INSTALL_DIR"
    bash ./traefik.sh start || {
        print_error "Stack start failed -- inspect: docker compose logs"
        exit 1
    }

    verify_upgrade || true
    print_upgrade_summary "$V2_BACKUP_DIR"
}

# =============================================================================
# Main
# =============================================================================
main() {
    # Upgrade subcommand short-circuits the normal install flow.
    if [[ "$UPGRADE_MODE" == true ]]; then
        upgrade_from_v2
        exit 0
    fi

    # Skip the banner/prereq run on the re-exec leg (already done in the
    # bootstrap pass). We pass the marker via the env so it survives exec.
    if [[ -z "${CS_TRAEFIK_REEXEC:-}" ]]; then
        print_banner
        require_root
        check_os
        ensure_basic_tools
        ensure_docker
    fi

    if [[ "$LOCAL_MODE" == false ]]; then
        # Remote bootstrap -- clone, then re-exec from the clone. The
        # re-exec hits LOCAL_MODE=true and finishes the install.
        clone_or_update_repo
        if [[ "$RUN_WIZARD" == false ]]; then
            print_info "--no-wizard set: skipping wizard + start."
            print_summary
            exit 0
        fi
        # Pass through user-relevant flags. We DON'T pass --branch / --install-dir
        # to the re-exec -- those were only relevant for the clone step.
        local re_exec_args=()
        [[ "$INTERACTIVE" == false ]]   && re_exec_args+=(--yes)
        [[ "$RECONFIGURE" == true ]]    && re_exec_args+=(--reconfigure)
        [[ "$START_STACK" == false ]]   && re_exec_args+=(--no-start)
        re_exec_from_clone "${re_exec_args[@]}"
        # exec replaces the process -- we never return here.
    fi

    # ---- LOCAL_MODE path ----
    if [[ "$RUN_WIZARD" == true ]]; then
        run_wizard
    fi
    start_stack
    print_summary
}

main "$@"
