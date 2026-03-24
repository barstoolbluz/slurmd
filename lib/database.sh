#!/usr/bin/env bash
# database.sh — MariaDB + slurmdbd setup
# Sourced by install.sh; requires common.sh to be loaded first.

install_database_packages() {
    log_step "Installing database packages"

    apt_install mariadb-server slurmdbd slurm-wlm-basic-plugins slurm-wlm-mysql-plugin

    log_success "Database packages installed."
}

configure_mariadb() {
    log_step "Configuring MariaDB for Slurm"

    # Start MariaDB first so we can configure it
    enable_and_start mariadb

    # Write InnoDB tuning config
    local conf_file="/etc/mysql/mariadb.conf.d/90-slurm.cnf"
    if [[ ! -f "$conf_file" ]]; then
        # Calculate buffer pool size: 25% of total RAM, minimum 256M
        local total_mem_kb
        total_mem_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
        local buffer_pool_mb=$(( total_mem_kb / 1024 / 4 ))
        if (( buffer_pool_mb < 256 )); then
            buffer_pool_mb=256
        fi

        cat > "$conf_file" <<EOF
[mysqld]
# Slurm-optimized InnoDB settings
innodb_buffer_pool_size = ${buffer_pool_mb}M
innodb_log_file_size = $(( buffer_pool_mb / 4 ))M
innodb_lock_wait_timeout = 900
max_allowed_packet = 16M
innodb_default_row_format = DYNAMIC
EOF
        log_info "Wrote MariaDB tuning config to ${conf_file}"
        log_info "  innodb_buffer_pool_size = ${buffer_pool_mb}M (25% of RAM)"

        # Restart to apply tuning
        systemctl restart mariadb
        log_success "MariaDB restarted with tuned settings."
    else
        log_info "MariaDB tuning config already exists at ${conf_file}."
    fi
}

create_slurm_database() {
    log_step "Creating Slurm accounting database"

    local db_name="${SLURM_DB_NAME:-slurm_acct_db}"
    local db_user="${SLURM_DB_USER:-slurm}"
    local db_pass="${SLURM_DB_PASS}"

    # Escape backslashes first, then single quotes, for safe SQL interpolation
    local db_pass_escaped="${db_pass//\\/\\\\}"
    db_pass_escaped="${db_pass_escaped//\'/\'\'}"

    # Check if database already exists
    if mysql -e "USE \`${db_name}\`" 2>/dev/null; then
        log_info "Database '${db_name}' already exists."
    else
        mysql -e "CREATE DATABASE \`${db_name}\`;"
        log_success "Created database '${db_name}'."
    fi

    # Create/update user and grants
    mysql <<EOF
CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass_escaped}';
GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost';
FLUSH PRIVILEGES;
EOF
    log_success "Database user '${db_user}' configured with full access to '${db_name}'."
}

generate_slurmdbd_conf() {
    log_step "Generating slurmdbd.conf"

    local conf_file="/etc/slurm/slurmdbd.conf"
    local template="${SCRIPT_DIR}/config/templates/slurmdbd.conf.tmpl"

    if [[ -f "$conf_file" ]]; then
        if confirm "Existing slurmdbd.conf found. Overwrite?" "default_no"; then
            backup_file "$conf_file"
        else
            log_info "Keeping existing slurmdbd.conf."
            return 0
        fi
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
        [DBD_HOSTNAME]="${DBD_HOSTNAME:-localhost}"
        [STORAGE_HOST]="localhost"
        [STORAGE_PORT]="3306"
        [STORAGE_DB_NAME]="${SLURM_DB_NAME:-slurm_acct_db}"
        [STORAGE_USER]="${SLURM_DB_USER:-slurm}"
        [STORAGE_PASS]="${SLURM_DB_PASS}"
    )

    render_template "$template" "$conf_file" vars

    # slurmdbd.conf MUST be 0600 owned by slurm:slurm
    # (slurmdbd runs as User=slurm and needs to read this file)
    chown slurm:slurm "$conf_file"
    chmod 0600 "$conf_file"

    log_success "slurmdbd.conf written to ${conf_file} (mode 0600)."
}

start_slurmdbd() {
    log_step "Starting slurmdbd"
    enable_and_start slurmdbd

    # Give slurmdbd a moment to fully initialize
    sleep 2
}

# ── Main entry point ───────────────────────────────────────────────────────

setup_database() {
    install_database_packages
    configure_mariadb
    create_slurm_database
    generate_slurmdbd_conf
    start_slurmdbd
}
