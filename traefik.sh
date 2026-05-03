#!/usr/bin/env bash
# =============================================================================
# CS-Traefik - Central Management Console
# =============================================================================
# Single entry point for all stack operations. Mirrors the runner.sh /
# coolify.sh pattern: subcommand dispatch with consistent flags.
#
# Usage:  ./traefik.sh <command> [options]
# Help:   ./traefik.sh help
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Paths
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ENV_FILE="$PROJECT_ROOT/.env"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
print_header() {
    echo -e "${BLUE}"
    echo "==============================================================================="
    echo "  CS-Traefik - $1"
    echo "==============================================================================="
    echo -e "${NC}"
}
print_info()    { echo -e "${BLUE}-->${NC} $1"; }
print_success() { echo -e "${GREEN}OK${NC}  $1"; }
print_warning() { echo -e "${YELLOW}!!${NC}  $1"; }
print_error()   { echo -e "${RED}XX${NC}  $1"; }

# -----------------------------------------------------------------------------
# Pre-flight
# -----------------------------------------------------------------------------
require_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        print_error ".env file missing at $ENV_FILE"
        echo "Run the wizard first:"
        echo "    sudo $PROJECT_ROOT/traefik.sh setup"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        print_error "Docker is not installed."
        exit 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        print_error "docker compose v2 plugin missing."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Compose command builder
# -----------------------------------------------------------------------------
# Reads COMPOSE_PROFILES from .env and constructs a `docker compose` invocation
# that loads the right overlay files. Profile names also need to be passed
# via --profile so services with `profiles:` keys actually start.
get_profiles() {
    if [[ -f "$ENV_FILE" ]]; then
        grep -E '^COMPOSE_PROFILES=' "$ENV_FILE" 2>/dev/null \
            | head -1 | cut -d'=' -f2- | tr -d ' "' || true
    fi
}

build_compose_cmd() {
    local profiles
    profiles=$(get_profiles)

    local files=("-f" "docker-compose.yml")
    local profile_flags=()

    if [[ -n "$profiles" ]]; then
        IFS=',' read -ra _profiles <<< "$profiles"
        for p in "${_profiles[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            [[ -z "$p" ]] && continue
            case "$p" in
                monitoring)
                    files+=("-f" "docker-compose.monitoring.yml")
                    profile_flags+=("--profile" "monitoring")
                    ;;
                auto-update)
                    files+=("-f" "docker-compose.auto-update.yml")
                    profile_flags+=("--profile" "auto-update")
                    ;;
                *)
                    print_warning "Unknown profile in COMPOSE_PROFILES: $p (ignored)"
                    ;;
            esac
        done
    fi

    echo "docker compose --env-file $ENV_FILE ${files[*]} ${profile_flags[*]}"
}

# Shorter helper -- invoke directly
compose() {
    local cmd
    cmd=$(build_compose_cmd)
    # shellcheck disable=SC2086
    eval "$cmd $*"
}

# -----------------------------------------------------------------------------
# Pre-up host preparation (data dirs + permissions)
# -----------------------------------------------------------------------------
ensure_data_dirs() {
    local data_dir
    data_dir=$(grep -E '^DATA_DIRECTORY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- || true)
    data_dir=${data_dir:-./data}

    # Resolve relative paths against PROJECT_ROOT
    if [[ "$data_dir" == ./* ]]; then
        data_dir="$PROJECT_ROOT/${data_dir#./}"
    fi

    print_info "Preparing data directory: $data_dir"

    mkdir -p "$data_dir"/traefik/{acme,logs}
    mkdir -p "$data_dir"/grafana
    mkdir -p "$data_dir"/prometheus
    mkdir -p "$data_dir"/loki
    mkdir -p "$data_dir"/promtail
    mkdir -p "$data_dir"/alertmanager

    # ACME storage MUST be 600 or Traefik refuses to use it.
    if [[ -f "$data_dir/traefik/acme/letsencrypt.json" ]]; then
        chmod 600 "$data_dir/traefik/acme/letsencrypt.json"
    fi
    chmod 700 "$data_dir/traefik/acme"

    # Grafana runs as 472:472, Loki as 10001:10001, Prometheus as 65534:65534
    if [[ $EUID -eq 0 ]]; then
        chown -R 472:472   "$data_dir/grafana"      2>/dev/null || true
        chown -R 65534:65534 "$data_dir/prometheus"  2>/dev/null || true
        chown -R 65534:65534 "$data_dir/alertmanager" 2>/dev/null || true
        chown -R 10001:10001 "$data_dir/loki"        2>/dev/null || true
    else
        print_warning "Not running as root -- skipping chown on data dirs."
        print_warning "If services fail to write, re-run with sudo."
    fi
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------

cmd_start() {
    print_header "Start"
    require_env
    check_docker
    ensure_data_dirs

    print_info "Bringing up the stack ..."
    compose up -d --remove-orphans

    echo
    print_success "Stack started."
    echo
    compose ps
    echo
}

cmd_stop() {
    print_header "Stop"
    require_env
    check_docker

    if ! compose ps -q 2>/dev/null | grep -q .; then
        print_warning "No containers currently running."
        return 0
    fi

    print_info "Stopping the stack ..."
    compose down

    echo
    print_success "Stack stopped (named volumes preserved)."
}

cmd_restart() {
    print_header "Restart"
    require_env
    check_docker

    print_info "Restarting the stack ..."
    compose restart

    echo
    print_success "Stack restarted."
    compose ps
}

cmd_status() {
    require_env
    check_docker

    print_header "Status"

    if ! compose ps -q 2>/dev/null | grep -q .; then
        print_warning "Stack is NOT running."
        echo
        echo "Start with:  sudo $0 start"
        return 0
    fi

    compose ps
    echo
    print_info "Resource usage:"
    docker stats --no-stream --format \
        "  {{.Name}}: CPU {{.CPUPerc}} | Mem {{.MemUsage}}" \
        "$(compose ps -q 2>/dev/null)" 2>/dev/null || true
    echo

    print_info "Active profiles:"
    local profiles
    profiles=$(get_profiles)
    echo "  ${profiles:-<core only>}"
}

cmd_logs() {
    require_env
    check_docker

    local service="${1:-}"
    if [[ -n "$service" ]]; then
        compose logs -f --tail=200 "$service"
    else
        compose logs -f --tail=100
    fi
}

cmd_update() {
    print_header "Update Images"
    require_env
    check_docker

    print_info "Pulling newer images ..."
    compose pull

    print_info "Recreating containers with the fresh images ..."
    compose up -d --remove-orphans

    print_info "Pruning old image layers ..."
    docker image prune -f >/dev/null

    echo
    print_success "Images updated."
    compose ps
}

cmd_deploy() {
    print_header "Deploy (git update)"

    if [[ ! -d "$PROJECT_ROOT/.git" ]]; then
        print_error "$PROJECT_ROOT is not a git checkout -- nothing to deploy."
        echo "Did you install via the one-line installer?"
        return 1
    fi

    cd "$PROJECT_ROOT"

    git config core.fileMode false 2>/dev/null || true
    git config --global --add safe.directory "$PROJECT_ROOT" 2>/dev/null || true

    print_info "Stashing local changes (if any) ..."
    local stashed=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        git stash push -m "auto-stash before deploy $(date +%Y%m%d-%H%M%S)" >/dev/null
        stashed=true
        print_warning "Local edits stashed."
    fi

    print_info "Pulling latest from origin ..."
    if ! git pull --ff-only; then
        print_warning "Fast-forward pull failed -- attempting merge ..."
        git pull
    fi

    if [[ "$stashed" == true ]]; then
        print_info "Restoring stashed changes ..."
        if git stash pop >/dev/null 2>&1; then
            print_success "Stash restored."
        else
            print_warning "Conflict on stash pop -- resolve manually:"
            echo "    git stash list"
            echo "    git stash show -p | git apply"
        fi
    fi

    chmod +x "$PROJECT_ROOT"/*.sh 2>/dev/null || true

    echo
    print_success "Repository updated."
    git log -1 --format='  Now at: %h %s (%cr)'
    echo
    echo "Next:  sudo $0 update    -- to also pull newer Docker images"
}

cmd_setup() {
    print_header "Setup Wizard"

    if [[ -x "$PROJECT_ROOT/install.sh" ]]; then
        # install.sh detects local-checkout mode automatically and runs the
        # wizard. --no-start because users typically want to review .env
        # before bringing the stack up; they can `start` explicitly after.
        "$PROJECT_ROOT/install.sh" --reconfigure --no-start "$@"
    else
        print_error "install.sh not found or not executable at $PROJECT_ROOT/install.sh"
        exit 1
    fi
}

cmd_validate() {
    print_header "Validate Configuration"
    require_env
    check_docker

    print_info "Compose config syntax check ..."
    if compose config -q; then
        print_success "Compose config is valid."
    else
        print_error "Compose config has errors."
        return 1
    fi

    print_info "Traefik config dry-run ..."
    if docker run --rm \
        -v "$PROJECT_ROOT/config/traefik:/etc/traefik:ro" \
        --entrypoint /bin/sh \
        traefik:v3.6 \
        -c "traefik --configFile=/etc/traefik/traefik.yml --check 2>&1 || traefik --configFile=/etc/traefik/traefik.yml 2>&1 | head -5" 2>&1 | head -30
    then
        print_success "Traefik config syntax accepted."
    else
        print_warning "Traefik check returned warnings -- inspect output above."
    fi
}

cmd_backup() {
    print_header "Backup"
    require_env
    check_docker

    local data_dir backup_dir timestamp backup_file
    data_dir=$(grep -E '^DATA_DIRECTORY=' "$ENV_FILE" | head -1 | cut -d'=' -f2-)
    [[ "$data_dir" == ./* ]] && data_dir="$PROJECT_ROOT/${data_dir#./}"
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="${data_dir}/backups"
    backup_file="${backup_dir}/edgeproxy_${timestamp}.tar.gz"

    mkdir -p "$backup_dir"

    print_info "Creating archive: $backup_file"
    tar -czf "$backup_file" \
        --exclude="$data_dir/loki/chunks" \
        --exclude="$data_dir/prometheus/wal" \
        --exclude="$backup_dir" \
        -C "$(dirname "$data_dir")" "$(basename "$data_dir")" \
        -C "$PROJECT_ROOT" .env config

    local size
    size=$(du -h "$backup_file" | cut -f1)

    echo
    print_success "Backup created: $backup_file ($size)"
    echo "  Contains: .env, config/, traefik/acme certs, grafana DB,"
    echo "            prometheus blocks (WAL excluded), alertmanager state."
}

cmd_destroy() {
    print_header "Destroy Stack"
    require_env
    check_docker

    print_warning "This will stop and remove ALL containers, networks, and named volumes"
    print_warning "for the '${STACK_NAME:-edgeproxy}' compose project."
    print_warning "Bind-mounted data (the DATA_DIRECTORY) is preserved."
    echo
    read -rp "Type 'destroy' to confirm: " confirm
    if [[ "$confirm" != "destroy" ]]; then
        print_info "Aborted."
        return 0
    fi

    print_info "Tearing the stack down ..."
    compose down -v --remove-orphans

    echo
    print_success "Stack destroyed."
    echo "Bind-mounted data still on disk -- delete manually if desired."
}

cmd_help() {
    cat <<EOF
${BOLD}CS-Traefik${NC} - Central Management Console

${BOLD}Usage:${NC}
    sudo ./traefik.sh <command> [options]

${BOLD}Stack lifecycle:${NC}
    start                Bring the stack up (creates dirs, sets perms)
    stop                 Stop containers (volumes preserved)
    restart              Restart all running services
    status               Show container state + resource usage
    logs [service]       Tail logs (all services, or a specific one)

${BOLD}Maintenance:${NC}
    update               Pull newer Docker images and recreate containers
    deploy               Pull newer scripts/configs from git (origin/main)
    setup                Re-run the interactive .env wizard
    validate             Syntax-check compose + traefik config
    backup               Snapshot .env, config, ACME certs, DBs to a tar.gz
    destroy              Tear down (containers + volumes; bind data kept)

${BOLD}Examples:${NC}
    sudo ./traefik.sh start              # bring up the active profile mix
    sudo ./traefik.sh logs traefik       # follow Traefik logs
    sudo ./traefik.sh update             # weekly image refresh
    sudo ./traefik.sh deploy             # pull new repo + scripts from git

${BOLD}Profiles:${NC}
    Profiles are toggled in .env via COMPOSE_PROFILES:
        COMPOSE_PROFILES=                       # core only (Traefik)
        COMPOSE_PROFILES=monitoring             # core + observability
        COMPOSE_PROFILES=monitoring,auto-update # everything

${BOLD}Documentation:${NC}
    README.md
EOF
}

# -----------------------------------------------------------------------------
# Dispatch
# -----------------------------------------------------------------------------
cd "$PROJECT_ROOT"

case "${1:-help}" in
    start)               shift; cmd_start    "$@" ;;
    stop|down)           shift; cmd_stop     "$@" ;;
    restart)             shift; cmd_restart  "$@" ;;
    status|ps)           shift; cmd_status   "$@" ;;
    logs|log)            shift; cmd_logs     "$@" ;;
    update|pull)         shift; cmd_update   "$@" ;;
    deploy)              shift; cmd_deploy   "$@" ;;
    setup|init)          shift; cmd_setup    "$@" ;;
    validate|check)      shift; cmd_validate "$@" ;;
    backup)              shift; cmd_backup   "$@" ;;
    destroy|nuke)        shift; cmd_destroy  "$@" ;;
    help|-h|--help|"")   cmd_help            ;;
    *)
        print_error "Unknown command: $1"
        echo
        cmd_help
        exit 1
        ;;
esac
