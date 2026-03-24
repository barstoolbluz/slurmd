#!/usr/bin/env bash
# munge.sh — MUNGE authentication setup
# Sourced by install.sh; requires common.sh to be loaded first.

MUNGE_KEY="/etc/munge/munge.key"

install_munge() {
    log_step "Installing MUNGE authentication"

    apt_install munge libmunge2

    log_success "MUNGE packages installed."
}

generate_munge_key() {
    log_info "Generating new MUNGE key..."

    if [[ -f "$MUNGE_KEY" ]]; then
        if confirm "Existing MUNGE key found. Overwrite it?" "default_no"; then
            backup_file "$MUNGE_KEY"
        else
            log_info "Keeping existing MUNGE key."
            return 0
        fi
    fi

    [[ -L "$MUNGE_KEY" ]] && die "Symlink detected at ${MUNGE_KEY} — refusing to proceed"
    dd if=/dev/urandom of="$MUNGE_KEY" bs=1024 count=1 2>/dev/null
    set_munge_permissions

    log_success "MUNGE key generated at ${MUNGE_KEY}"
    echo
    log_warn "IMPORTANT: You must copy this key to ALL other nodes in the cluster."
    log_warn "The key must be identical on every node."
    echo
    log_info "To copy the key to another node, run:"
    echo -e "  ${CYAN}sudo scp ${MUNGE_KEY} root@<node>:${MUNGE_KEY}${RESET}"
    echo -e "  ${CYAN}ssh root@<node> 'chown munge:munge ${MUNGE_KEY} && chmod 0400 ${MUNGE_KEY}'${RESET}"
    echo
}

import_munge_key() {
    log_info "This node needs the MUNGE key from the controller."
    echo

    if [[ -f "$MUNGE_KEY" ]]; then
        log_info "Existing MUNGE key found at ${MUNGE_KEY}."
        if confirm "Keep the existing key?" "default_yes"; then
            set_munge_permissions
            return 0
        fi
    fi

    echo -e "You can provide the MUNGE key in one of two ways:"
    echo -e "  ${CYAN}1)${RESET} Specify a path to a key file (e.g., copied via scp)"
    echo -e "  ${CYAN}2)${RESET} Paste the base64-encoded key content"
    echo

    menu_select "How would you like to provide the MUNGE key?" \
        "Path to key file" \
        "Paste base64-encoded key"
    local method="$REPLY"

    case "$method" in
        1)
            prompt_input "Path to MUNGE key file"
            local key_path="$REPLY"

            if [[ ! -f "$key_path" ]]; then
                die "File not found: ${key_path}"
            fi

            cp "$key_path" "$MUNGE_KEY"
            log_success "MUNGE key imported from ${key_path}"
            ;;
        2)
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
