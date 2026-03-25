#!/usr/bin/env bash
# munge.sh — MUNGE authentication setup
# Sourced by install.sh; requires common.sh to be loaded first.

MUNGE_KEY="/etc/munge/munge.key"

install_munge() {
    log_step "Installing MUNGE authentication"

    # Note: Debian's munge package postinst script automatically generates a key
    # via `mungekey -c` if /etc/munge/munge.key doesn't exist. This means a fresh
    # install will already have a key before generate_munge_key() runs.
    apt_install munge libmunge2

    log_success "MUNGE packages installed."
}

generate_munge_key() {
    log_info "Generating new MUNGE key..."

    if [[ -f "$MUNGE_KEY" ]]; then
        local key_size
        key_size=$(stat -c%s "$MUNGE_KEY" 2>/dev/null || echo 0)

        # Debian's munge postinst runs `mungekey -c` which creates a 128-byte
        # (1024-bit) key. Our dd command creates a 1024-byte key. If we see a
        # 128-byte key, it's almost certainly the auto-generated throwaway.
        if (( key_size == 128 )); then
            echo
            log_warn "An existing MUNGE key was found, but it appears to be the"
            log_warn "auto-generated key created by the Debian munge package during"
            log_warn "installation. This key is unique to this machine and won't"
            log_warn "work with other nodes in your cluster."
            echo
            log_info "For the controller node, you should generate a new key and"
            log_info "distribute it to all other nodes."
            echo
            if confirm "Replace the auto-generated key with a new one?" "default_yes"; then
                backup_file "$MUNGE_KEY"
            else
                log_info "Keeping existing MUNGE key."
                return 0
            fi
        else
            # Key exists but isn't the 128-byte auto-generated size — likely
            # intentionally created or imported from another node.
            if confirm "Existing MUNGE key found. Overwrite it?" "default_no"; then
                backup_file "$MUNGE_KEY"
            else
                log_info "Keeping existing MUNGE key."
                return 0
            fi
        fi
    fi

    [[ -L "$MUNGE_KEY" ]] && die "Symlink detected at ${MUNGE_KEY} — refusing to proceed"
    dd if=/dev/urandom of="$MUNGE_KEY" bs=1024 count=1 2>/dev/null
    set_munge_permissions

    log_success "MUNGE key generated at ${MUNGE_KEY}"
    echo
    log_warn "IMPORTANT: You must copy this key to ALL other nodes in the cluster."
    log_warn "The key must be identical on every node, owned by munge:munge with mode 0400."
    echo
}

fetch_munge_key_from_controller() {
    local controller="${CONTROLLER_HOSTNAME:-}"

    if [[ -z "$controller" ]]; then
        prompt_input "Controller hostname or IP"
        controller="$REPLY"
    fi

    local default_user
    default_user=$(whoami)
    prompt_input "SSH username for ${controller}" "$default_user"
    local ssh_user="$REPLY"

    local ssh_target="${ssh_user}@${controller}"

    log_info "Fetching MUNGE key from ${ssh_target}..."
    echo -e "${YELLOW}You may be prompted for your SSH password and/or sudo password.${RESET}"
    echo

    # Try to fetch the key - need sudo on remote since key is 0400 munge:munge
    # Use base64 encoding to safely transfer binary data over SSH with tty
    local tmp_key
    tmp_key=$(mktemp)
    local tmp_b64
    tmp_b64=$(mktemp)

    # Fetch the key as base64 (using -tt for sudo password prompt support)
    # The base64 encoding avoids binary transfer issues with tty mode
    if ssh -tt -o ConnectTimeout=10 "$ssh_target" "sudo base64 /etc/munge/munge.key" > "$tmp_b64" 2>/dev/null; then
        # Remove any tty artifacts (carriage returns, terminal escapes) and decode
        # Keep only valid base64 characters and newlines
        tr -cd 'A-Za-z0-9+/=\n' < "$tmp_b64" | base64 -d > "$tmp_key" 2>/dev/null

        # Verify we got something reasonable (should be 1024 bytes for our generated keys, or 128 for default)
        local key_size
        key_size=$(stat -c%s "$tmp_key" 2>/dev/null || echo 0)
        if (( key_size < 128 )); then
            rm -f "$tmp_key" "$tmp_b64"
            die "Failed to fetch MUNGE key (file too small or empty). Check sudo permissions on controller."
        fi

        cp "$tmp_key" "$MUNGE_KEY"
        rm -f "$tmp_key" "$tmp_b64"
        log_success "MUNGE key fetched from ${controller}"
    else
        rm -f "$tmp_key" "$tmp_b64"
        echo
        log_error "Failed to fetch MUNGE key from ${controller}."
        log_info "Ensure you can SSH to the controller and have sudo access."
        log_info "You may need to run: ssh-copy-id ${ssh_target}"
        die "Could not retrieve MUNGE key."
    fi
}

import_munge_key() {
    log_info "This node needs the MUNGE key from the controller."
    echo

    if [[ -f "$MUNGE_KEY" ]]; then
        local key_size
        key_size=$(stat -c%s "$MUNGE_KEY" 2>/dev/null || echo 0)

        # Detect the auto-generated 128-byte key from Debian's munge postinst
        if (( key_size == 128 )); then
            echo
            log_warn "An existing MUNGE key was found, but it appears to be the"
            log_warn "auto-generated key created by the Debian munge package."
            log_warn "This key won't match the controller's key."
            echo
            log_info "You need to import the MUNGE key from your controller node."
            echo
        else
            # Key exists and isn't the auto-generated size — might be valid
            log_info "Existing MUNGE key found at ${MUNGE_KEY}."
            if confirm "Keep the existing key?" "default_yes"; then
                set_munge_permissions
                return 0
            fi
        fi
    fi

    echo -e "How would you like to provide the MUNGE key?"
    echo -e "  ${CYAN}1)${RESET} Fetch from controller via SSH (recommended)"
    echo -e "  ${CYAN}2)${RESET} Specify a path to a local key file"
    echo -e "  ${CYAN}3)${RESET} Paste the base64-encoded key content"
    echo

    menu_select "Choose an option:" \
        "Fetch from controller via SSH (recommended)" \
        "Path to local key file" \
        "Paste base64-encoded key"
    local method="$REPLY"

    case "$method" in
        1)
            fetch_munge_key_from_controller
            ;;
        2)
            prompt_input "Path to MUNGE key file"
            local key_path="$REPLY"

            if [[ ! -f "$key_path" ]]; then
                die "File not found: ${key_path}"
            fi

            cp "$key_path" "$MUNGE_KEY"
            log_success "MUNGE key imported from ${key_path}"
            ;;
        3)
            echo -e "On the controller, run: ${CYAN}sudo base64 ${MUNGE_KEY}${RESET}"
            echo "Then paste the output below."
            prompt_input "Base64-encoded MUNGE key"
            printf '%s\n' "$REPLY" | base64 -d > "$MUNGE_KEY"
            log_success "MUNGE key decoded and written."
            ;;
    esac

    set_munge_permissions
}

set_munge_permissions() {
    [[ -L "$MUNGE_KEY" ]] && die "Symlink detected at ${MUNGE_KEY} — refusing to proceed"
    chown munge:munge "$MUNGE_KEY"
    chmod 0400 "$MUNGE_KEY"

    # Fix directory permissions too
    chown munge:munge /etc/munge
    chmod 0700 /etc/munge

    if [[ -d /var/log/munge ]]; then
        chown munge:munge /var/log/munge
        chmod 0700 /var/log/munge
    fi

    if [[ -d /run/munge ]]; then
        chown munge:munge /run/munge
        chmod 0755 /run/munge
    fi
}

start_munge() {
    log_step "Starting MUNGE service"
    enable_and_start munge
}

verify_munge() {
    log_step "Verifying MUNGE"

    if ! command -v munge &>/dev/null; then
        log_error "munge command not found."
        return 1
    fi

    local result
    if result=$(munge -n 2>&1 | unmunge 2>&1); then
        log_success "MUNGE is working (local credential encode/decode OK)."
    else
        log_error "MUNGE verification failed: ${result}"
        log_error "Check: journalctl -xeu munge"
        return 1
    fi
}

# ── Main entry point ───────────────────────────────────────────────────────

# Usage: setup_munge "generate" | "import"
setup_munge() {
    local mode="${1:-import}"

    install_munge

    case "$mode" in
        generate)
            generate_munge_key
            ;;
        import)
            import_munge_key
            ;;
    esac

    start_munge
    verify_munge
}
