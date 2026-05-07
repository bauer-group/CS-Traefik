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
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

usage() {
    cat <<EOF
CS-Traefik - Unified Installer & Setup Wizard

Usage:
  curl -fsSL <repo>/install.sh | sudo bash [-- options]   # remote bootstrap
  sudo ./install.sh [options]                             # local re-configure

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
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes|-y)            INTERACTIVE=false; shift ;;
        --reconfigure)       RECONFIGURE=true;  shift ;;
        --setup-only)        START_STACK=false; shift ;;
        --no-start)          START_STACK=false; shift ;;
        --no-wizard)         RUN_WIZARD=false; START_STACK=false; shift ;;
        --branch|-b)         BRANCH="$2";       shift 2 ;;
        --install-dir|-d)    INSTALL_DIR="$2";  shift 2 ;;
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

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
        read -rp "Install Docker via the official convenience script? [Y/n] " ans
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
clone_or_update_repo() {
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
                read -rp "Move it aside and clone fresh? [y/N] " ans
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

ask() {
    # ask "Prompt text" "default-value"  -> echoes the user's answer
    local prompt="$1" default="${2:-}"
    if [[ "$INTERACTIVE" == false ]]; then
        echo "$default"
        return
    fi
    local response
    if [[ -n "$default" ]]; then
        read -rp "$(echo -e "${BOLD}? ${prompt}${NC} [${YELLOW}${default}${NC}]: ")" response
        echo "${response:-$default}"
    else
        read -rp "$(echo -e "${BOLD}? ${prompt}${NC}: ")" response
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
    read -rp "$(echo -e "${BOLD}? ${prompt}${NC} [${YELLOW}${default_label}${NC}]: ")" response
    response=${response:-$default}
    [[ "$response" =~ ^[Yy]$ ]] && echo "yes" || echo "no"
}

set_env() {
    # set_env KEY VALUE -- updates or appends in $ENV_FILE
    local key="$1" value="$2" escaped
    escaped=$(printf '%s' "$value" | sed -e 's/[\\&|]/\\&/g')
    if grep -qE "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
    else
        echo "${key}=${value}" >> "$ENV_FILE"
    fi
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

    cp "$ENV_EXAMPLE" "$ENV_FILE"
    print_success "Created $ENV_FILE from template."

    # Defaults derived from the host
    local default_tz default_host default_domain
    default_tz=$(cat /etc/timezone 2>/dev/null || echo "Etc/UTC")
    default_host=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost")
    default_domain="${default_host#*.}"
    [[ "$default_domain" == "$default_host" ]] && default_domain="example.com"

    # ---- Stack identity ----
    print_section "Stack identity"
    local stack_name network_name time_zone data_dir
    stack_name=$(ask "Compose project name (lowercase)" "edgeproxy")
    network_name=$(ask "Public network name (legacy default: EDGEPROXY)" "EDGEPROXY")
    time_zone=$(ask "Timezone (IANA name)" "$default_tz")
    # Default `./data` keeps runtime state under the install dir but in
    # a clearly-separated, gitignored subdirectory. Overriding to an
    # absolute path is only needed if the operator wants state on a
    # separate disk / volume / NFS share. Never suggest the install
    # dir itself (would mix repo files with runtime state).
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
        read -rp "$(echo -e "${BOLD}? Mode${NC} [1=localhost / 2=LAN / 3=public FQDN] [${YELLOW}1${NC}]: ")" mode_choice
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
            read -rsp "$(echo -e "${BOLD}? Admin password${NC}: ")" admin_pass
            echo
        fi
    else
        admin_pass=$(generate_password)
    fi

    print_info "Generating bcrypt hash ..."
    auth_string=$(generate_basic_auth "$admin_user" "$admin_pass")
    set_env API_USERS "$auth_string"
    admin_pass_display="$admin_pass"

    # ---- Let's Encrypt ----
    print_section "Let's Encrypt"
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
            read -rsp "$(echo -e "${BOLD}? Grafana admin password${NC}: ")" grafana_pass
            echo
        else
            grafana_pass=$(generate_password)
        fi
        set_env GRAFANA_ADMIN_PASSWORD "$grafana_pass"
        grafana_pass_display="$grafana_pass"
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
# Main
# =============================================================================
main() {
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
