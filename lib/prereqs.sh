#!/usr/bin/env bash
# prereqs.sh — system prerequisites for all Slurm node types
# Sourced by install.sh; requires common.sh to be loaded first.

# ── Time synchronization ───────────────────────────────────────────────────

setup_time_sync() {
    log_step "Configuring time synchronization"

    # Check if any time sync service is already running
    if is_service_active "chrony" || is_service_active "chronyd" || is_service_active "systemd-timesyncd" || is_service_active "ntp" || is_service_active "ntpd"; then
        log_success "Time synchronization service already running."
        return 0
    fi

    # Check if chrony is already installed (but not running)
    local chrony_preinstalled=false
    if dpkg -l chrony 2>/dev/null | grep -q '^ii'; then
        chrony_preinstalled=true
    fi

    log_info "Installing chrony for NTP time synchronization..."
    apt_install chrony
    enable_and_start chrony

    # Record only if we actually installed it
    if ! $chrony_preinstalled; then
        record_installed_package "chrony"
    fi

    log_success "Time synchronization configured with chrony."
}

# ── Slurm user and group ───────────────────────────────────────────────────

setup_slurm_user() {
    log_step "Configuring slurm system user/group"

    local slurm_uid="${SLURM_UID:-64030}"
    local slurm_gid="${SLURM_GID:-64030}"

    # Create group if it doesn't exist
    if getent group slurm &>/dev/null; then
        local existing_gid
        existing_gid=$(getent group slurm | cut -d: -f3)
        log_info "Group 'slurm' already exists (GID: ${existing_gid})."

        if [[ "$existing_gid" != "$slurm_gid" ]]; then
            log_warn "Existing GID (${existing_gid}) differs from requested (${slurm_gid})."
            log_warn "Ensure this GID is consistent across ALL cluster nodes."
        fi
    else
        groupadd --gid "$slurm_gid" slurm
        log_success "Created group 'slurm' (GID: ${slurm_gid})."
    fi

    # Create user if it doesn't exist
    if id -u slurm &>/dev/null; then
        local existing_uid
        existing_uid=$(id -u slurm)
        log_info "User 'slurm' already exists (UID: ${existing_uid})."

        if [[ "$existing_uid" != "$slurm_uid" ]]; then
            log_warn "Existing UID (${existing_uid}) differs from requested (${slurm_uid})."
            log_warn "Ensure this UID is consistent across ALL cluster nodes."
        fi
    else
        useradd --uid "$slurm_uid" --gid slurm \
            --system --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "Slurm workload manager" \
            slurm
        log_success "Created user 'slurm' (UID: ${slurm_uid})."
    fi
}

# ── Directories ─────────────────────────────────────────────────────────────

setup_directories() {
    log_step "Creating Slurm directories"

    local dirs=(
        /etc/slurm
        /var/log/slurm
        /var/lib/slurm
    )

    # Role-specific directories
    case "${NODE_ROLE:-}" in
        controller|controller_db)
            dirs+=(/var/lib/slurm/slurmctld)
            ;;
        compute)
            dirs+=(/var/lib/slurm/slurmd)
            ;;
    esac

    for dir in "${dirs[@]}"; do
        if [[ -L "$dir" ]]; then
            die "Symlink detected at ${dir} — refusing to proceed"
        fi
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            log_info "Created ${dir}"
        fi
        chown slurm:slurm "$dir"
        chmod 0755 "$dir"
    done

    log_success "Slurm directories ready."
}

# ── Firewall ────────────────────────────────────────────────────────────────

setup_firewall() {
    log_step "Configuring firewall rules"

    # Only configure if ufw is present and active
    if ! command -v ufw &>/dev/null; then
        log_info "ufw not installed — skipping firewall configuration."
        log_warn "Ensure the following ports are open manually if you have a firewall:"
        print_firewall_requirements
        return 0
    fi

    if ! ufw status | grep -q "Status: active"; then
        log_info "ufw is installed but not active — skipping."
        log_warn "If you enable ufw later, open these ports:"
        print_firewall_requirements
        return 0
    fi

    case "${NODE_ROLE:-}" in
        controller|controller_db)
            ufw allow 6817/tcp comment "slurmctld"
            ufw allow 6818/tcp comment "slurmd (for responses)"
            if [[ "${NODE_ROLE}" == "controller_db" ]]; then
                ufw allow 6819/tcp comment "slurmdbd"
            fi
            ;;
        database)
            ufw allow 6819/tcp comment "slurmdbd"
            ;;
        compute)
            ufw allow 6818/tcp comment "slurmd"
            ;;
        login)
            # Login nodes only make outbound connections
            ;;
    esac

    log_success "Firewall rules applied."
}

print_firewall_requirements() {
    case "${NODE_ROLE:-}" in
        controller|controller_db)
            log_info "  - TCP 6817 (slurmctld) — inbound from all cluster nodes"
            if [[ "${NODE_ROLE}" == "controller_db" ]]; then
                log_info "  - TCP 6819 (slurmdbd) — inbound from controller"
            fi
            ;;
        database)
            log_info "  - TCP 6819 (slurmdbd) — inbound from controller"
            ;;
        compute)
            log_info "  - TCP 6818 (slurmd) — inbound from controller"
            ;;
        login)
            log_info "  - No inbound ports required (outbound to controller on 6817)"
            ;;
    esac
}

# ── Main entry point ───────────────────────────────────────────────────────

install_prereqs() {
    apt_update_if_stale
    setup_time_sync
    setup_slurm_user
    setup_directories
    setup_firewall
}
