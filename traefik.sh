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
# BASH_SOURCE may be unset under `set -u` if this script is ever sourced
# from a context that didn't populate it. Guard with ${BASH_SOURCE[0]:-$0}.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
ENV_FILE="$PROJECT_ROOT/.env"

# -----------------------------------------------------------------------------
# Colors
# -----------------------------------------------------------------------------
# ANSI-C ($'...') quoting stores the actual ESC byte (0x1B) in the variable,
# not a 7-character literal "\033[1m". That way `cat <<EOF` (used in cmd_help)
# renders the colors correctly without needing `echo -e` everywhere.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

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
# Lifecycle summary helpers (information awareness after every action)
# -----------------------------------------------------------------------------

# get_env_value KEY -- read a key from .env, echo the value (no quotes, trim)
get_env_value() {
    [[ -f "$ENV_FILE" ]] || { echo ""; return; }
    grep -E "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2- | sed 's/^"\(.*\)"$/\1/; s/^'\''\(.*\)'\''$/\1/' || echo ""
}

# resolve_data_dir -- expand ./data relative to PROJECT_ROOT
resolve_data_dir() {
    local d
    d=$(get_env_value DATA_DIRECTORY)
    d=${d:-./data}
    [[ "$d" == ./* ]] && d="$PROJECT_ROOT/${d#./}"
    echo "$d"
}

# Container summary used by lifecycle commands. Prints to stdout:
#   * a short table of container name + status + health
#   * total / healthy / unhealthy / starting counts
print_container_state() {
    local total healthy unhealthy starting other
    if ! compose ps -q 2>/dev/null | grep -q .; then
        echo "  No containers running."
        return 1
    fi

    # Count by health (or running state when no healthcheck)
    total=$(compose ps -q 2>/dev/null | wc -l | tr -d ' ')
    healthy=$(compose ps --format '{{.Health}}' 2>/dev/null | grep -c '^healthy$' || true)
    unhealthy=$(compose ps --format '{{.Health}}' 2>/dev/null | grep -c '^unhealthy$' || true)
    starting=$(compose ps --format '{{.Health}}' 2>/dev/null | grep -c '^starting$' || true)
    other=$((total - healthy - unhealthy - starting))

    echo "  Containers: total=$total  healthy=$healthy  starting=$starting  unhealthy=$unhealthy  no-healthcheck=$other"
    echo
    compose ps --format 'table {{.Service}}\t{{.Status}}' 2>/dev/null | sed 's/^/    /'
    return 0
}

# Print the standard "where to access / what to do next" block.
# Tailored to whether the stack is currently running or stopped.
print_access_info() {
    local running="${1:-true}"   # true|false
    local profiles api_port api_bind data_dir api_host

    profiles=$(get_profiles)
    api_port=$(get_env_value API_PORT); api_port=${api_port:-9090}
    api_bind=$(get_env_value API_BIND); api_bind=${api_bind:-127.0.0.1}
    api_host=$(get_env_value API_HOST)
    data_dir=$(resolve_data_dir)

    echo "  ${BOLD}Profiles active:${NC} ${profiles:-<core only>}"
    echo

    if [[ "$running" == true ]]; then
        echo "  ${BOLD}Admin access:${NC}"
        if [[ "$api_bind" == "0.0.0.0" || "$api_bind" == "::" ]]; then
            echo "    LAN-accessible at:  http://<host-ip>:${api_port}/dashboard/"
            echo "    Loopback (always):  http://127.0.0.1:${api_port}/dashboard/"
        else
            echo "    Localhost-only:     http://${api_bind}:${api_port}/dashboard/"
            echo "    SSH-tunnel from your workstation:"
            echo "      ssh -L ${api_port}:${api_bind}:${api_port} root@<this-host>"
        fi
        if [[ -n "$api_host" && "$api_host" != "__api_host_not_set__"* ]]; then
            echo "    Public FQDN (mode 3): https://${api_host}/dashboard/"
        fi
        if [[ "$profiles" == *"monitoring"* ]]; then
            echo
            echo "    Monitoring UIs (same auth as dashboard):"
            echo "      /grafana/        Grafana home"
            echo "      /prometheus/     Prometheus query UI"
            echo "      /alertmanager/   Alertmanager"
        fi
        echo
    fi

    echo "  ${BOLD}Key paths:${NC}"
    echo "    Configuration:  $ENV_FILE  (chmod 600)"
    echo "    Data directory: $data_dir/  (gitignored, runtime state)"
    echo "    Compose root:   $PROJECT_ROOT/"
    echo

    echo "  ${BOLD}Useful commands:${NC}"
    echo "    sudo $0 status            container state + resource usage"
    echo "    sudo $0 logs [service]    tail logs (all or one service)"
    if [[ "$running" == true ]]; then
        echo "    sudo $0 restart           restart all running services"
        echo "    sudo $0 stop              stop the stack (volumes preserved)"
    else
        echo "    sudo $0 start             bring the stack back up"
    fi
    echo "    sudo $0 backup            snapshot .env, config, ACME, DBs"
    echo "    sudo $0 check-host-isolation  verify host hardening (read-only)"
    echo
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

    mkdir -p "$data_dir"/traefik/{letsencrypt,logs}
    mkdir -p "$data_dir"/grafana
    mkdir -p "$data_dir"/prometheus
    mkdir -p "$data_dir"/loki
    mkdir -p "$data_dir"/promtail
    mkdir -p "$data_dir"/alertmanager

    # ACME storage files MUST be 600 or Traefik refuses to use them.
    # Tighten any existing files (renewals replace them in-place).
    chmod 700 "$data_dir/traefik/letsencrypt"
    if compgen -G "$data_dir/traefik/letsencrypt/*.json" > /dev/null; then
        chmod 600 "$data_dir/traefik/letsencrypt/"*.json
    fi

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
    print_section "Summary"
    print_container_state
    echo
    print_access_info true
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
    print_success "Stack stopped."
    echo
    print_section "Summary"
    echo "  All containers stopped. Networks removed."
    echo "  ${BOLD}Preserved:${NC}"
    echo "    * Named volumes (none in this stack -- all bind-mounts)"
    echo "    * Bind-mounted data directory (see below)"
    echo "    * .env configuration"
    echo
    print_access_info false
}

cmd_restart() {
    print_header "Restart"
    require_env
    check_docker

    print_info "Restarting the stack ..."
    compose restart

    echo
    print_success "Stack restarted."
    echo
    print_section "Summary"
    print_container_state
    echo
    print_access_info true
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

    # Snapshot pre-update image IDs so we can show what actually changed.
    local pre_state
    pre_state=$(compose ps --format '{{.Service}}={{.Image}}' 2>/dev/null | sort)

    print_info "Pulling newer images ..."
    compose pull

    print_info "Recreating containers with the fresh images ..."
    compose up -d --remove-orphans

    print_info "Pruning old image layers ..."
    docker image prune -f >/dev/null

    # Diff pre/post image IDs to highlight what actually got newer.
    local post_state
    post_state=$(compose ps --format '{{.Service}}={{.Image}}' 2>/dev/null | sort)
    local changed
    changed=$(diff <(echo "$pre_state") <(echo "$post_state") 2>/dev/null | grep -E '^[<>]' || true)

    echo
    print_success "Images updated."
    echo
    print_section "Summary"
    if [[ -z "$changed" ]]; then
        echo "  No image updates picked up (everything was already current)."
    else
        echo "  Image changes detected:"
        echo "$changed" | sed 's|^<|    [pre]  |; s|^>|    [post] |'
    fi
    echo
    print_container_state
    echo
    print_access_info true
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

cmd_check_host_isolation() {
    print_header "Host Isolation Check"

    local issues=0

    # ---- 1. Docker engine OOM protection -----------------------------------
    print_info "Checking dockerd OOM protection..."
    if command -v systemctl >/dev/null 2>&1; then
        local docker_unit
        docker_unit=$(systemctl show docker 2>/dev/null | grep -E "^OOMScoreAdjust=" | cut -d= -f2)
        if [[ -z "$docker_unit" || "$docker_unit" == "0" ]]; then
            print_warning "dockerd.service has no OOMScoreAdjust (or 0). Under extreme memory"
            print_warning "pressure on this host, the kernel could pick dockerd as an OOM"
            print_warning "victim before killing other less-important processes."
            print_warning ""
            print_warning "Recommended fix (one-time, does not touch CS-Traefik):"
            print_warning "  sudo systemctl edit docker"
            print_warning "  # add: [Service]"
            print_warning "  #      OOMScoreAdjust=-500"
            print_warning "  sudo systemctl daemon-reload && sudo systemctl restart docker"
            issues=$((issues + 1))
        else
            print_success "dockerd OOMScoreAdjust=$docker_unit (kernel-protected)"
        fi
    else
        print_warning "systemctl not available -- cannot verify dockerd OOM protection."
        print_warning "Skipping (Docker Desktop / non-systemd host)."
    fi
    echo

    # ---- 2. SSH daemon OOM protection --------------------------------------
    print_info "Checking sshd OOM protection..."
    if command -v systemctl >/dev/null 2>&1; then
        local sshd_unit
        sshd_unit=$(systemctl show sshd ssh 2>/dev/null | grep -E "^OOMScoreAdjust=" | cut -d= -f2 | head -1)
        if [[ -z "$sshd_unit" || "$sshd_unit" == "0" ]]; then
            print_warning "sshd has no OOMScoreAdjust. Under OOM pressure you might lose your"
            print_warning "remote shell. Same fix pattern as for dockerd above (sudo systemctl"
            print_warning "edit ssh / sshd, add OOMScoreAdjust=-500)."
            issues=$((issues + 1))
        else
            print_success "sshd OOMScoreAdjust=$sshd_unit"
        fi
    fi
    echo

    # ---- 3. Verify our container OOM scores --------------------------------
    print_info "Checking running container OOM scores (if stack is up)..."
    if check_docker 2>/dev/null && docker ps --format '{{.Names}}' | grep -q "${STACK_NAME:-edgeproxy}"; then
        for c in ${STACK_NAME:-edgeproxy}-traefik ${STACK_NAME:-edgeproxy}-prometheus ${STACK_NAME:-edgeproxy}-grafana; do
            if docker inspect "$c" >/dev/null 2>&1; then
                local pid
                pid=$(docker inspect -f '{{.State.Pid}}' "$c")
                if [[ "$pid" != "0" && -r "/proc/$pid/oom_score_adj" ]]; then
                    local adj
                    adj=$(cat "/proc/$pid/oom_score_adj")
                    case "$c" in
                        *-traefik)
                            if [[ "$adj" == "-50" ]]; then
                                print_success "$c oom_score_adj=$adj (light bias, sits with apps below sshd/dockerd)"
                            else
                                print_warning "$c oom_score_adj=$adj (expected -50)"
                                issues=$((issues + 1))
                            fi
                            ;;
                        *)
                            if [[ "$adj" == "200" ]]; then
                                print_success "$c oom_score_adj=$adj (preferred victim, OK)"
                            else
                                print_warning "$c oom_score_adj=$adj (expected 200)"
                                issues=$((issues + 1))
                            fi
                            ;;
                    esac
                else
                    print_info "$c -- /proc not readable (Docker Desktop / non-Linux host)"
                fi
            fi
        done
    else
        print_info "Stack not running -- skip live OOM-score check."
    fi
    echo

    # ---- 4. Data directory mount ------------------------------------------
    print_info "Checking ${DATA_DIRECTORY:-./data} mount layout..."
    if [[ -d "${DATA_DIRECTORY:-./data}" ]]; then
        if command -v df >/dev/null 2>&1; then
            local data_fs
            data_fs=$(df --output=source "${DATA_DIRECTORY:-./data}" 2>/dev/null | tail -1)
            local root_fs
            root_fs=$(df --output=source / 2>/dev/null | tail -1)
            if [[ "$data_fs" == "$root_fs" ]]; then
                print_warning "DATA_DIRECTORY (${DATA_DIRECTORY:-./data}) is on the same"
                print_warning "filesystem as / -- a Prometheus / Loki write spike can"
                print_warning "starve the OS root I/O. For production, mount this on a"
                print_warning "dedicated volume."
            else
                print_success "DATA_DIRECTORY on separate filesystem ($data_fs)"
            fi
        fi
    fi
    echo

    # ---- Summary -----------------------------------------------------------
    if [[ $issues -eq 0 ]]; then
        print_success "Host isolation looks good -- the stack will not put Traefik or"
        print_success "host-critical processes at risk under memory pressure."
    else
        print_warning "$issues recommendation(s) above. The stack still runs safely; these"
        print_warning "are extra hardening steps for production deployments. None of"
        print_warning "them affect CS-Traefik containers -- they are host-side concerns."
    fi
}

cmd_migrate_acme() {
    print_header "Migrate ACME Certificates from Legacy Stack"
    require_env

    # ---- Argument parsing -------------------------------------------------
    local source_file=""
    local source_resolver="letsencrypt"
    local target_resolver="letsencrypt-tls"
    local target_file=""
    local dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --source|--src)              source_file="$2"; shift 2 ;;
            --source-resolver)           source_resolver="$2"; shift 2 ;;
            --target-resolver)           target_resolver="$2"; shift 2 ;;
            --target)                    target_file="$2"; shift 2 ;;
            --dry-run|-n)                dry_run=true; shift ;;
            -h|--help)
                cat <<HELP
${BOLD}Usage:${NC} sudo ./traefik.sh migrate-acme --source <path> [options]

${BOLD}Options:${NC}
    --source <path>            REQUIRED. Path to the legacy v2 letsencrypt.json
                               (e.g. /opt/edgeproxy-v2/traefik/certificates/dynamic/letsencrypt.json).
    --source-resolver <name>   Resolver key in the source file. Default: letsencrypt
                               (matches the legacy v2 stack convention).
    --target-resolver <name>   Resolver to write into the new stack. Default:
                               letsencrypt-tls (preserves the TLS-ALPN-01 challenge
                               type the v2 stack used). Other options:
                                 letsencrypt          (HTTP-01)
                                 letsencrypt-dns      (DNS-01 / wildcards)
                                 letsencrypt-staging  (testing)
    --target <path>            Override the destination path. Default:
                               \${DATA_DIRECTORY}/traefik/letsencrypt/<target-resolver>.json
    --dry-run, -n              Print what WOULD migrate without writing.

${BOLD}Examples:${NC}
    # typical migration (v2 letsencrypt -> v3 letsencrypt-tls)
    sudo ./traefik.sh migrate-acme \\
        --source /opt/edgeproxy-v2/traefik/certificates/dynamic/letsencrypt.json

    # dry-run first to see what would be moved
    sudo ./traefik.sh migrate-acme --source ./old-letsencrypt.json --dry-run

    # if the legacy stack used DNS-01 instead, target the dns resolver
    sudo ./traefik.sh migrate-acme \\
        --source ./old.json --target-resolver letsencrypt-dns

${BOLD}What it does:${NC}
    Reads <source> (a Traefik v2 ACME storage file) and merges its
    certificates + ACME account into the new stack's <target>. Existing
    certs in the target with the same main domain are REPLACED (the
    legacy cert wins, since it is what serves real traffic right now);
    certs for other domains are kept. The ACME account block is taken
    from the source so renewals continue under the existing Let's
    Encrypt registration -- avoids a fresh \`new-account\` call that
    would burn rate-limit budget.

    Permissions are set to 0600 (Traefik refuses ACME files at any
    other mode). The existing target is backed up to <target>.bak.<ts>
    before being overwritten.

${BOLD}This subcommand is transient.${NC} Once all legacy certs have been
    migrated and renewed once successfully under the new stack, you
    can stop using it. The script stays in the repo as documentation
    of the migration, but day-to-day operations no longer need it.
HELP
                return 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Run: sudo ./traefik.sh migrate-acme --help"
                return 1
                ;;
        esac
    done

    if [[ -z "$source_file" ]]; then
        print_error "--source is required. Run with --help for usage."
        return 1
    fi
    if [[ ! -f "$source_file" ]]; then
        print_error "Source file does not exist: $source_file"
        return 1
    fi

    # ---- Resolve target path ---------------------------------------------
    local data_dir="${DATA_DIRECTORY:-./data}"
    if [[ -z "$target_file" ]]; then
        target_file="$data_dir/traefik/letsencrypt/${target_resolver}.json"
    fi
    local target_dir
    target_dir="$(dirname "$target_file")"

    print_info "Source file       : $source_file"
    print_info "Source resolver   : $source_resolver"
    print_info "Target file       : $target_file"
    print_info "Target resolver   : $target_resolver"
    if $dry_run; then
        print_warning "DRY-RUN -- no files will be written"
    fi
    echo

    if [[ ! -d "$target_dir" ]]; then
        if $dry_run; then
            print_info "(would mkdir -p $target_dir)"
        else
            mkdir -p "$target_dir"
        fi
    fi

    # ---- Locate a usable Python interpreter ------------------------------
    # python3 on Linux production, python on some Windows / Git-Bash setups.
    local py=""
    for candidate in python3 python; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)" >/dev/null 2>&1; then
            py="$candidate"
            break
        fi
    done
    if [[ -z "$py" ]]; then
        print_error "Python 3.6+ is required for migration but was not found in PATH."
        print_error "Install python3 (apt install python3 / apk add python3) and retry."
        return 1
    fi

    # ---- Run the migration via inline Python -----------------------------
    # Python rather than jq for portability -- present on every Linux box,
    # and the merge logic is more readable than a jq one-liner.
    "$py" - "$source_file" "$source_resolver" "$target_file" "$target_resolver" "$dry_run" <<'PYEOF'
import json, os, sys, time

src_path, src_resolver, dst_path, dst_resolver, dry = sys.argv[1:6]
dry = dry.lower() == "true"

# ---- Load source -----------------------------------------------------------
try:
    with open(src_path, "r", encoding="utf-8") as f:
        src = json.load(f)
except json.JSONDecodeError as e:
    print(f"XX  Source is not valid JSON: {e}")
    sys.exit(2)

if src_resolver not in src:
    print(f"XX  Resolver '{src_resolver}' not found in source. Available keys: {list(src.keys())}")
    sys.exit(2)

src_block = src[src_resolver]
src_account = src_block.get("Account", {})
src_certs = src_block.get("Certificates") or []
if not src_certs:
    print(f"!!  Source resolver '{src_resolver}' has no certificates -- nothing to migrate.")
    sys.exit(0)

print(f"-->  Source has {len(src_certs)} certificate(s):")
for c in src_certs:
    main = c.get("domain", {}).get("main", "?")
    sans = c.get("domain", {}).get("sans") or []
    san_str = f" + {len(sans)} SANs" if sans else ""
    print(f"    {main}{san_str}")

# ---- Load destination (if exists) ------------------------------------------
dst = {}
existing_certs = []
if os.path.exists(dst_path):
    try:
        with open(dst_path, "r", encoding="utf-8") as f:
            dst = json.load(f)
        existing_certs = dst.get(dst_resolver, {}).get("Certificates") or []
        print(f"-->  Target exists: {len(existing_certs)} cert(s) currently under '{dst_resolver}'")
    except json.JSONDecodeError:
        print(f"!!  Target exists but is not valid JSON -- it will be replaced.")

# ---- Merge: source certs replace existing same-domain entries ------------
src_domains = {c.get("domain", {}).get("main") for c in src_certs}
kept = [c for c in existing_certs if c.get("domain", {}).get("main") not in src_domains]
merged_certs = kept + src_certs
replaced = len(existing_certs) - len(kept)

print()
print(f"OK  Merge plan:")
print(f"    Source certs added/replaced : {len(src_certs)}")
print(f"    Existing same-domain replaced: {replaced}")
print(f"    Existing other-domain kept   : {len(kept)}")
print(f"    Total in target after merge  : {len(merged_certs)}")
print()

# Build the new target block. ACME Account from source preserves the LE
# registration so renewals continue without a fresh `new-account` call
# (which would consume rate-limit budget AND temporarily disconnect the
# stack from its previous account-key audit trail).
new_block = {
    "Account": src_account,
    "Certificates": merged_certs,
}
dst[dst_resolver] = new_block

if dry:
    print("-->  Dry-run -- target not written.")
    sys.exit(0)

# ---- Backup existing destination (if any) ---------------------------------
if os.path.exists(dst_path):
    bak = f"{dst_path}.bak.{int(time.time())}"
    os.rename(dst_path, bak)
    print(f"OK  Existing target backed up to: {bak}")

# ---- Write new destination + chmod 0600 -----------------------------------
with open(dst_path, "w", encoding="utf-8") as f:
    json.dump(dst, f, indent=2)
os.chmod(dst_path, 0o600)
print(f"OK  Wrote {dst_path} (mode 0600)")
PYEOF

    local rc=$?
    if [[ $rc -ne 0 ]]; then
        print_error "Migration failed (exit $rc)"
        return $rc
    fi

    if ! $dry_run; then
        echo
        print_success "Migration complete."
        echo "  Next steps:"
        echo "    1. Restart Traefik so it picks up the migrated certs:"
        echo "         sudo ./traefik.sh restart"
        echo "    2. Verify each migrated cert is loaded -- in the dashboard"
        echo "       under HTTP -> TLS -> Certificates, confirm the SAN list."
        echo "    3. Hit each migrated host to confirm the cert serves correctly:"
        echo "         curl -vI https://<your-host>"
        echo "    4. Watch ACME renewal logs for the next few weeks -- Traefik"
        echo "       renews ~30 days before expiry. The first renewal proves"
        echo "       the migrated Account block works against Let's Encrypt."
    fi
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
    check-host-isolation Verify host-side hardening (dockerd / sshd OOM
                         protection, data-dir on separate FS, container
                         OOM scores live). Read-only -- no host changes.
    destroy              Tear down (containers + volumes; bind data kept)

${BOLD}Migration (transient):${NC}
    migrate-acme         Import ACME certs from a legacy v2 stack's
                         letsencrypt.json. Run with --help for usage.
                         Will become obsolete once all certs renew once.

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
    check-host-isolation) shift; cmd_check_host_isolation "$@" ;;
    migrate-acme)        shift; cmd_migrate_acme "$@" ;;
    destroy|nuke)        shift; cmd_destroy  "$@" ;;
    help|-h|--help|"")   cmd_help            ;;
    *)
        print_error "Unknown command: $1"
        echo
        cmd_help
        exit 1
        ;;
esac
