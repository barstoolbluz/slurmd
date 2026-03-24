#!/usr/bin/env bash
# controller.sh — slurmctld (controller node) setup
# Sourced by install.sh; requires common.sh to be loaded first.

install_controller_packages() {
    log_step "Installing controller packages"

    apt_install slurmctld slurm-client slurm-wlm-basic-plugins

    log_success "Controller packages installed."
}

generate_slurm_conf() {
    log_step "Generating slurm.conf"

    local conf_file="/etc/slurm/slurm.conf"
    local template="${SCRIPT_DIR}/config/templates/slurm.conf.tmpl"

    if [[ -f "$conf_file" ]]; then
        if confirm "Existing slurm.conf found. Overwrite?" "default_no"; then
            backup_file "$conf_file"
        else
            log_info "Keeping existing slurm.conf."
            return 0
        fi
    fi

    # Build accounting storage lines
    local acct_type="accounting_storage/none"
    local acct_extra="# No accounting database configured."

    if [[ "${NODE_ROLE}" == "controller_db" ]]; then
        acct_type="accounting_storage/slurmdbd"
        acct_extra="AccountingStorageHost=localhost"
    elif [[ -n "${DBD_HOSTNAME:-}" ]]; then
        acct_type="accounting_storage/slurmdbd"
        acct_extra="AccountingStorageHost=${DBD_HOSTNAME}"
    fi

    # Build node definitions
    local node_defs=""
    local partition_defs=""

    if [[ -n "${COMPUTE_NODES:-}" ]]; then
        node_defs="$COMPUTE_NODES"
        # Extract node names for the partition line
        local node_names
        node_names=$(echo "$COMPUTE_NODES" | grep -oP 'NodeName=\K[^\s]+' | paste -sd',' -)
        partition_defs="PartitionName=${PARTITION_NAME:-batch} Nodes=${node_names} Default=YES MaxTime=INFINITE State=UP"
    else
        node_defs="# No compute nodes configured yet."
        node_defs="${node_defs}"$'\n'"# Run 'slurmd -C' on each compute node and add the output here."
        node_defs="${node_defs}"$'\n'"# Example:"
        node_defs="${node_defs}"$'\n'"# NodeName=compute01 CPUs=16 RealMemory=64000 Sockets=1 CoresPerSocket=8 ThreadsPerCore=2 State=UNKNOWN"
        partition_defs="# PartitionName=batch Nodes=compute[01-10] Default=YES MaxTime=INFINITE State=UP"
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
        [CLUSTER_NAME]="${CLUSTER_NAME}"
        [CONTROLLER_HOSTNAME]="${CONTROLLER_HOSTNAME}"
        [ACCOUNTING_STORAGE_TYPE]="${acct_type}"
        [ACCOUNTING_STORAGE_EXTRA]="${acct_extra}"
        [NODE_DEFINITIONS]="${node_defs}"
        [PARTITION_DEFINITIONS]="${partition_defs}"
    )

    render_template "$template" "$conf_file" vars

    chown root:slurm "$conf_file"
    chmod 0640 "$conf_file"

    log_success "slurm.conf written to ${conf_file}."
    log_info "This file must be copied identically to all other cluster nodes."
}

generate_cgroup_conf() {
    local conf_file="/etc/slurm/cgroup.conf"
    local template="${SCRIPT_DIR}/config/templates/cgroup.conf.tmpl"

    if [[ -f "$conf_file" ]]; then
        log_info "cgroup.conf already exists, keeping it."
        return 0
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
    )

    render_template "$template" "$conf_file" vars

    chown root:slurm "$conf_file"
    chmod 0640 "$conf_file"

    log_info "cgroup.conf written to ${conf_file}."
}

start_slurmctld() {
    log_step "Starting slurmctld"
    enable_and_start slurmctld
}

register_cluster() {
    log_step "Registering cluster in accounting database"

    if [[ "${NODE_ROLE}" != "controller_db" && -z "${DBD_HOSTNAME:-}" ]]; then
        log_info "No accounting database — skipping cluster registration."
        return 0
    fi

    # Wait a moment for slurmdbd to be fully ready
    sleep 2

    # Check if cluster is already registered
    if sacctmgr -n show cluster "${CLUSTER_NAME}" 2>/dev/null | grep -Fqw "${CLUSTER_NAME}"; then
        log_info "Cluster '${CLUSTER_NAME}' is already registered."
    else
        sacctmgr -i add cluster "${CLUSTER_NAME}"
        log_success "Cluster '${CLUSTER_NAME}' registered."
    fi
}

# ── Main entry point ───────────────────────────────────────────────────────

setup_controller() {
    install_controller_packages
    generate_slurm_conf
    generate_cgroup_conf
    start_slurmctld
    register_cluster
}
