#!/usr/bin/env bash
# login.sh — login node setup (client tools only, no daemons)
# Sourced by install.sh; requires common.sh to be loaded first.

install_login_packages() {
    log_step "Installing login node packages"

    apt_install slurm-client slurm-wlm-basic-plugins

    log_success "Login node packages installed."
}

setup_slurm_conf_login() {
    log_step "Setting up slurm.conf on login node"

    local conf_file="/etc/slurm/slurm.conf"

    if [[ -f "$conf_file" ]]; then
        log_info "slurm.conf already exists at ${conf_file}."
        if ! confirm "Overwrite with new configuration?" "default_no"; then
            return 0
        fi
        backup_file "$conf_file"
    fi

    echo
    echo -e "The login node needs the ${BOLD}same slurm.conf${RESET} as the controller."
    echo

    menu_select "How would you like to provide slurm.conf?" \
        "Path to existing slurm.conf (copied from controller)" \
        "Generate a minimal one now"
    local method="$REPLY"

    case "$method" in
        1)
            prompt_input "Path to slurm.conf"
            local src_path="$REPLY"

            if [[ ! -f "$src_path" ]]; then
                die "File not found: ${src_path}"
            fi

            cp "$src_path" "$conf_file"
            log_success "slurm.conf copied from ${src_path}."
            ;;
        2)
            generate_slurm_conf_login
            ;;
    esac

    chown root:root "$conf_file"
    chmod 0644 "$conf_file"
}

generate_slurm_conf_login() {
    local conf_file="/etc/slurm/slurm.conf"
    local template="${SCRIPT_DIR}/config/templates/slurm.conf.tmpl"

    if [[ -z "${CLUSTER_NAME:-}" ]]; then
        prompt_input "Cluster name (must match controller)"
        CLUSTER_NAME="$REPLY"
    fi
    if [[ -z "${CONTROLLER_HOSTNAME:-}" ]]; then
        prompt_input "Controller hostname (must match controller)"
        CONTROLLER_HOSTNAME="$REPLY"
    fi

    local acct_type="accounting_storage/none"
    local acct_extra="# No accounting database configured."

    if [[ -n "${DBD_HOSTNAME:-}" ]]; then
        acct_type="accounting_storage/slurmdbd"
        acct_extra="AccountingStorageHost=${DBD_HOSTNAME}"
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
        [CLUSTER_NAME]="${CLUSTER_NAME}"
        [CONTROLLER_HOSTNAME]="${CONTROLLER_HOSTNAME}"
        [ACCOUNTING_STORAGE_TYPE]="${acct_type}"
        [ACCOUNTING_STORAGE_EXTRA]="${acct_extra}"
        [NODE_DEFINITIONS]="# Node definitions must match the controller"
        [PARTITION_DEFINITIONS]="# Partition definitions must match the controller"
    )

    render_template "$template" "$conf_file" vars
    log_success "slurm.conf generated at ${conf_file}."
    log_warn "You MUST ensure this file matches the controller's slurm.conf exactly."
}

# ── Main entry point ───────────────────────────────────────────────────────

setup_login() {
    install_login_packages
    setup_slurm_conf_login
    log_success "Login node setup complete. No daemons to start — client tools only."
}
