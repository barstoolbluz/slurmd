#!/usr/bin/env bash
# database.sh — MariaDB + slurmdbd setup
# Sourced by install.sh; requires common.sh to be loaded first.

# Global: whether to use containerized MariaDB (set by choose_mariadb_method)
USE_MARIADB_CONTAINER=false
# Global: whether we're reusing an existing MariaDB installation
REUSE_EXISTING_MARIADB=false

# ── Native MariaDB Functions ──────────────────────────────────────────────────

install_database_packages_native() {
    log_step "Installing database packages (native)"

    # Check if MariaDB is already installed
    local mariadb_preinstalled=false
    if dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
        mariadb_preinstalled=true
    fi

    apt_install mariadb-server slurmdbd slurm-wlm-basic-plugins slurm-wlm-mysql-plugin

    # Record only if we actually installed MariaDB
    if ! $mariadb_preinstalled; then
        record_installed_package "mariadb-server"
    fi

    log_success "Database packages installed."
}

configure_mariadb_native() {
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

create_slurm_database_native() {
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

# ── Containerized MariaDB Functions ───────────────────────────────────────────

install_database_packages_container() {
    log_step "Installing database packages (container)"

    # Only need slurmdbd and plugins, not mariadb-server
    apt_install slurmdbd slurm-wlm-basic-plugins slurm-wlm-mysql-plugin mariadb-client

    record_installed_package "mariadb-container"

    log_success "Database packages installed (MariaDB will run in container)."
}

setup_mariadb_container() {
    log_step "Setting up MariaDB container"

    local db_name="${SLURM_DB_NAME:-slurm_acct_db}"
    local db_user="${SLURM_DB_USER:-slurm}"
    local db_pass="${SLURM_DB_PASS}"

    # Generate a random root password for the container
    local root_pass
    root_pass=$(generate_password 24)

    # Create data directory
    local data_dir="/var/lib/slurm-mariadb"
    if [[ ! -d "$data_dir" ]]; then
        mkdir -p "$data_dir"
        chmod 755 "$data_dir"
        log_info "Created data directory ${data_dir}"
    fi

    # Create systemd service from template
    local service_file="/etc/systemd/system/slurm-mariadb.service"
    local template="${SCRIPT_DIR}/config/templates/mariadb-container.service.tmpl"

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
        [CONTAINER_RUNTIME]="${CONTAINER_RUNTIME}"
        [MARIADB_ROOT_PASSWORD]="${root_pass}"
        [MARIADB_DATABASE]="${db_name}"
        [MARIADB_USER]="${db_user}"
        [MARIADB_PASSWORD]="${db_pass}"
    )

    render_template "$template" "$service_file" vars
    chmod 644 "$service_file"
    log_info "Created systemd service ${service_file}"

    # Reload systemd and start the service
    systemctl daemon-reload

    # Pull the image first (may take a while)
    log_info "Pulling MariaDB container image (this may take a moment)..."
    if ! $CONTAINER_RUNTIME pull docker.io/library/mariadb:lts; then
        die "Failed to pull MariaDB container image"
    fi
    log_success "Container image pulled."

    # Start the service
    enable_and_start slurm-mariadb

    log_success "MariaDB container started."
}

wait_for_mariadb_container() {
    log_step "Waiting for MariaDB container to be ready"

    local max_attempts=60
    local attempt=1

    while (( attempt <= max_attempts )); do
        if mysql -h 127.0.0.1 -u root -e "SELECT 1" &>/dev/null 2>&1 || \
           mysql -h 127.0.0.1 -u "${SLURM_DB_USER:-slurm}" -p"${SLURM_DB_PASS}" -e "SELECT 1" &>/dev/null 2>&1; then
            log_success "MariaDB is ready."
            return 0
        fi
        echo -n "."
        sleep 2
        (( attempt++ ))
    done

    echo
    log_error "MariaDB container did not become ready in time."
    log_info "Check container logs: ${CONTAINER_RUNTIME} logs slurm-mariadb"
    return 1
}

create_slurm_database_container() {
    log_step "Verifying Slurm database in container"

    local db_name="${SLURM_DB_NAME:-slurm_acct_db}"
    local db_user="${SLURM_DB_USER:-slurm}"

    # The container's MARIADB_DATABASE and MARIADB_USER env vars should have
    # created the database and user automatically. Verify they exist.
    if mysql -h 127.0.0.1 -u "$db_user" -p"${SLURM_DB_PASS}" -e "USE \`${db_name}\`" 2>/dev/null; then
        log_success "Database '${db_name}' and user '${db_user}' are ready."
    else
        log_warn "Database may not be fully initialized. Checking..."
        # Give it a bit more time and retry
        sleep 5
        if mysql -h 127.0.0.1 -u "$db_user" -p"${SLURM_DB_PASS}" -e "USE \`${db_name}\`" 2>/dev/null; then
            log_success "Database '${db_name}' and user '${db_user}' are ready."
        else
            die "Failed to verify database. Check container logs: ${CONTAINER_RUNTIME} logs slurm-mariadb"
        fi
    fi
}

# ── Shared Functions ──────────────────────────────────────────────────────────

choose_mariadb_method() {
    log_step "MariaDB installation method"

    # Check for existing installations
    local has_native=false
    local has_container=false

    if dpkg -l mariadb-server 2>/dev/null | grep -q '^ii'; then
        has_native=true
    fi

    if [[ -f /etc/systemd/system/slurm-mariadb.service ]]; then
        has_container=true
    fi

    # If either exists, ask if they want to use the existing one
    if $has_native; then
        log_info "Native MariaDB is already installed."
        if confirm "Use the existing native MariaDB installation?" "default_yes"; then
            USE_MARIADB_CONTAINER=false
            REUSE_EXISTING_MARIADB=true
            return 0
        fi
    fi

    if $has_container; then
        log_info "MariaDB container service already exists."
        if confirm "Use the existing MariaDB container?" "default_yes"; then
            USE_MARIADB_CONTAINER=true
            REUSE_EXISTING_MARIADB=true
            detect_container_runtime || die "Container runtime not found but container service exists"
            return 0
        fi
    fi

    # Check for container runtime availability
    local container_available=false
    if detect_container_runtime; then
        container_available=true
    fi

    echo
    echo -e "MariaDB can be installed ${BOLD}natively${RESET} or run in a ${BOLD}container${RESET}."
    echo
    echo -e "  ${CYAN}Native:${RESET}    Uses Debian's mariadb-server package"
    echo -e "             Integrated with system, familiar to sysadmins"
    echo
    echo -e "  ${CYAN}Container:${RESET} Runs MariaDB in a Docker/Podman container"
    echo -e "             Isolated, easy upgrades, consistent across Debian versions"
    if ! $container_available; then
        echo -e "             ${YELLOW}(Requires Docker or Podman - not currently installed)${RESET}"
    fi
    echo

    if $container_available; then
        menu_select "How would you like to run MariaDB?" \
            "Native (Debian package)" \
            "Container (${CONTAINER_RUNTIME})"
        case "$REPLY" in
            1) USE_MARIADB_CONTAINER=false ;;
            2) USE_MARIADB_CONTAINER=true ;;
        esac
    else
        echo -e "${YELLOW}No container runtime found.${RESET} Using native MariaDB."
        echo
        if confirm "Would you like to install a container runtime instead?" "default_no"; then
            echo
            menu_select "Which container runtime would you like to install?" \
                "Podman (recommended)" \
                "Docker"
            case "$REPLY" in
                1)
                    log_info "Installing Podman..."
                    apt_install podman
                    CONTAINER_RUNTIME="podman"
                    USE_MARIADB_CONTAINER=true
                    ;;
                2)
                    log_info "Installing Docker..."
                    apt_install docker.io
                    CONTAINER_RUNTIME="docker"
                    USE_MARIADB_CONTAINER=true
                    ;;
            esac
        else
            USE_MARIADB_CONTAINER=false
        fi
    fi
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

    # For container, we connect via TCP to 127.0.0.1; for native, use localhost socket
    local storage_host="localhost"
    if $USE_MARIADB_CONTAINER; then
        storage_host="127.0.0.1"
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
        [DBD_HOSTNAME]="${DBD_HOSTNAME:-localhost}"
        [STORAGE_HOST]="${storage_host}"
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
    setup_service_defaults "slurmdbd" "SLURMDBD_OPTIONS"

    # If using container, ensure slurmdbd depends on it
    if $USE_MARIADB_CONTAINER; then
        # Create drop-in to add dependency
        local dropin_dir="/etc/systemd/system/slurmdbd.service.d"
        mkdir -p "$dropin_dir"
        cat > "${dropin_dir}/container-dependency.conf" <<EOF
[Unit]
After=slurm-mariadb.service
Requires=slurm-mariadb.service
EOF
        systemctl daemon-reload
        log_info "Added slurmdbd dependency on MariaDB container."
    fi

    enable_and_start slurmdbd

    # Give slurmdbd a moment to fully initialize
    sleep 2
}

# ── Main entry point ───────────────────────────────────────────────────────

setup_database() {
    choose_mariadb_method

    if $USE_MARIADB_CONTAINER; then
        install_database_packages_container
        if $REUSE_EXISTING_MARIADB; then
            log_info "Using existing MariaDB container."
            # Ensure the container is running
            if ! systemctl is-active --quiet slurm-mariadb; then
                systemctl start slurm-mariadb
            fi
            wait_for_mariadb_container
        else
            setup_mariadb_container
            wait_for_mariadb_container
            create_slurm_database_container
        fi
    else
        install_database_packages_native
        if $REUSE_EXISTING_MARIADB; then
            log_info "Using existing native MariaDB."
            # Ensure MariaDB is running
            if ! systemctl is-active --quiet mariadb; then
                systemctl start mariadb
            fi
        else
            configure_mariadb_native
            create_slurm_database_native
        fi
    fi

    generate_slurmdbd_conf
    start_slurmdbd
}

# Legacy function names for compatibility (in case other scripts call them)
install_database_packages() { install_database_packages_native; }
configure_mariadb() { configure_mariadb_native; }
create_slurm_database() { create_slurm_database_native; }
