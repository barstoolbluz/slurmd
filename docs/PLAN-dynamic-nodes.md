# Plan: Dynamic Node Discovery (Configless Slurm)

## Overview

Implement Slurm's "configless" mode combined with dynamic node registration for Debian 12+ systems, simplifying compute node setup while maintaining the current manual workflow for Debian 11.

**Current workflow (manual):**
1. Install slurmd on compute node
2. Run `slurmd -C` to get hardware line
3. Send NodeName line to cluster admin
4. Admin adds line to slurm.conf on controller
5. Admin runs `--setup-nodes` to distribute slurm.conf and munge.key to compute node
6. Start slurmd

**New workflow (dynamic mode, Debian 12+):**
1. Install slurmd on compute node
2. Import munge.key from controller (still required)
3. Configure `/etc/default/slurmd` with controller address
4. Start slurmd → fetches config from controller and self-registers

**What dynamic mode eliminates:**
- Pre-defining NodeName lines in slurm.conf
- Distributing slurm.conf to compute nodes

**What dynamic mode still requires:**
- Munge key distribution (authentication)
- Local gres.conf for GPU auto-detection (GRES not auto-detected in dynamic mode)
- `MaxNodeCount` configured on controller

---

## Slurm Version Requirements

| Feature | Minimum Version | Debian Availability |
|---------|-----------------|---------------------|
| Configless Slurm | 20.02 | Debian 11 (20.11), 12 (22.05), 13 (24.x) |
| Dynamic Nodes | 22.05 | Debian 12+, 13 |

**Decision:** Target Debian 12+ for dynamic mode. Debian 11 has configless but not dynamic nodes—implementing configless-only would still require NodeName pre-definition, providing minimal benefit.

**Sources:**
- [Configless Slurm Documentation](https://slurm.schedmd.com/configless_slurm.html)
- [Dynamic Nodes Documentation](https://slurm.schedmd.com/dynamic_nodes.html)
- [Debian Package Versions](https://tracker.debian.org/pkg/slurm-wlm)

---

## How Configless + Dynamic Nodes Work

### Controller Side

1. `SlurmctldParameters=enable_configless` — allows nodes to fetch config
2. `MaxNodeCount=N` — maximum dynamic nodes allowed (required for dynamic nodes)
3. `PartitionName=batch Nodes=ALL` — partition accepts any registered node

### Compute Node Side

1. **No local slurm.conf** — slurmd fetches it from controller
2. **`--conf-server` option** — tells slurmd where the controller is
3. **`-Z` option** — registers as a dynamic node with auto-detected hardware
4. **Munge key required** — authentication still needed

The slurmd command becomes:
```bash
slurmd --conf-server controller:6817 -Z
```

This is configured via `/etc/default/slurmd`:
```bash
SLURMD_OPTIONS="--conf-server controller:6817 -Z"
```

The Debian systemd unit already reads this file:
```ini
EnvironmentFile=-/etc/default/slurmd
ExecStart=/usr/sbin/slurmd --systemd $SLURMD_OPTIONS
```

### GPU/GRES Limitation

Per [slurmd documentation](https://slurm.schedmd.com/slurmd.html):

> "-Z: Start this node as a Dynamic Normal node. If no --conf is specified, then the slurmd will register with the same hardware configuration **(except GRES)** as defined by the -C option."

**GPUs are NOT auto-detected in dynamic mode.** Options:
1. Manually specify: `--conf "Gres=gpu:2"` in SLURMD_OPTIONS
2. Keep local gres.conf (slurmd still reads it)
3. Hybrid: gres.conf for AutoDetect, slurmd -Z for registration

**Recommendation:** Keep current gres.conf generation for GPU nodes. The installer already does this correctly.

---

## Architecture Analysis

### Current Code Structure

```
install.sh
├── collect_config()          # Gathers COMPUTE_NODES from user input
├── gather_compute_nodes()    # Interactive NodeName entry
├── setup_remote_nodes()      # --setup-nodes entry point
│   ├── distribute_to_node()  # Pushes slurm.conf, munge.key to nodes
│   └── review_node_configs() # Updates NodeName lines via SSH
│
lib/controller.sh
├── generate_slurm_conf()     # Builds slurm.conf from COMPUTE_NODES
│   └── NODE_DEFINITIONS      # Templated into slurm.conf
│
lib/compute.sh
├── setup_compute()           # Main compute node flow
├── setup_slurm_conf_compute() # 4 options for getting slurm.conf
│   ├── Fetch from controller via SSH
│   ├── Path to local file
│   ├── Skip (pushed later)
│   └── Generate from scratch
│
lib/common.sh
├── require_debian()          # Sets DEBIAN_VERSION global
├── setup_service_defaults()  # Creates /etc/default/<service> files
│
config/templates/slurm.conf.tmpl
└── %%NODE_DEFINITIONS%%      # Where NodeName lines go
```

### Key Globals

| Variable | Purpose | Where Set |
|----------|---------|-----------|
| `DEBIAN_VERSION` | OS version detection | `require_debian()` in common.sh |
| `COMPUTE_NODES` | Multi-line NodeName definitions | `collect_config()` |
| `CONTROLLER_HOSTNAME` | SlurmctldHost value | `collect_config()` |
| `CONTROLLER_IS_COMPUTE` | Controller also runs slurmd | `collect_config()` |

---

## Implementation Plan

### Phase 1: Version Detection & Mode Selection

**File: `lib/common.sh`**

Add global and helper:

```bash
# Dynamic node mode (set based on Debian version and user choice)
USE_DYNAMIC_NODES=false

# Check if dynamic nodes are supported (Slurm 22.05+ = Debian 12+)
supports_dynamic_nodes() {
    [[ "${DEBIAN_VERSION:-0}" -ge 12 ]]
}
```

**File: `install.sh`**

In `collect_config()`, for controller roles, add mode selection:

```bash
case "$NODE_ROLE" in
    controller|controller_db)
        if supports_dynamic_nodes; then
            echo
            log_info "This Slurm version supports dynamic node discovery."
            log_info "Compute nodes can self-register without pre-configuration."
            log_info "You'll still need to distribute the munge key to each node."

            if confirm "Enable dynamic node discovery?" "default_yes"; then
                USE_DYNAMIC_NODES=true
                log_success "Dynamic mode enabled."

                prompt_input "Maximum number of compute nodes" "100"
                MAX_NODE_COUNT="$REPLY"
            else
                log_info "Using traditional mode. Nodes must be pre-defined."
            fi
        fi
        ;;
esac
```

### Phase 2: Controller Changes

**File: `lib/controller.sh`**

Modify `generate_slurm_conf()`:

```bash
generate_slurm_conf() {
    # ... existing setup ...

    local node_defs=""
    local partition_defs=""
    local slurmctld_params=""
    local max_node_count=""

    if [[ "${USE_DYNAMIC_NODES:-false}" == "true" ]]; then
        # Dynamic mode configuration
        slurmctld_params="SlurmctldParameters=enable_configless"
        max_node_count="MaxNodeCount=${MAX_NODE_COUNT:-100}"

        # Nodes=ALL accepts any registered node
        partition_defs="PartitionName=${PARTITION_NAME:-batch} Nodes=ALL Default=YES MaxTime=INFINITE State=UP"

        node_defs="# Dynamic node mode enabled"
        node_defs="${node_defs}"$'\n'"# Compute nodes self-register — no NodeName lines needed"
        node_defs="${node_defs}"$'\n'"# Run './install.sh --setup-nodes' to distribute munge keys"

        # Still include controller if it's also a compute node (pre-defined)
        if [[ -n "${CONTROLLER_NODENAME:-}" ]]; then
            node_defs="${node_defs}"$'\n'$'\n'"# Controller node (pre-defined, also runs jobs):"
            node_defs="${node_defs}"$'\n'"${CONTROLLER_NODENAME}"
        fi
    else
        # Traditional mode: existing logic unchanged
        if [[ -n "${COMPUTE_NODES:-}" ]]; then
            node_defs="$COMPUTE_NODES"
            local node_names
            node_names=$(echo "$COMPUTE_NODES" | grep -oP 'NodeName=\K[^\s]+' | paste -sd',' -)
            partition_defs="PartitionName=${PARTITION_NAME:-batch} Nodes=${node_names} Default=YES MaxTime=INFINITE State=UP"
        else
            node_defs="# No compute nodes configured yet."
            node_defs="${node_defs}"$'\n'"# Run 'slurmd -C' on each compute node and add the output here."
            partition_defs="# PartitionName=batch Nodes=compute[01-10] Default=YES MaxTime=INFINITE State=UP"
        fi
    fi

    declare -A vars=(
        [GENERATED_DATE]="$(date '+%Y-%m-%d %H:%M:%S')"
        [CLUSTER_NAME]="${CLUSTER_NAME}"
        [CONTROLLER_HOSTNAME]="${CONTROLLER_HOSTNAME}"
        [SLURMCTLD_PARAMETERS]="${slurmctld_params}"
        [MAX_NODE_COUNT]="${max_node_count}"
        [ACCOUNTING_STORAGE_TYPE]="${acct_type}"
        [ACCOUNTING_STORAGE_EXTRA]="${acct_extra}"
        [GRES_TYPES]="${gres_types}"
        [NODE_DEFINITIONS]="${node_defs}"
        [PARTITION_DEFINITIONS]="${partition_defs}"
    )

    render_template "$template" "$conf_file" vars
    # ...
}
```

**File: `config/templates/slurm.conf.tmpl`**

Add new placeholders:

```conf
# ── Cluster identity ──────────────────────────────────────────────────────

ClusterName=%%CLUSTER_NAME%%
SlurmctldHost=%%CONTROLLER_HOSTNAME%%

# ── Controller parameters ─────────────────────────────────────────────────
%%SLURMCTLD_PARAMETERS%%
%%MAX_NODE_COUNT%%

# ... rest unchanged ...
```

### Phase 3: Compute Node Changes

**File: `lib/compute.sh`**

Add function to configure dynamic mode:

```bash
# Configure slurmd for dynamic/configless mode.
# Sets up /etc/default/slurmd with --conf-server and -Z options.
# No local slurm.conf is created — slurmd fetches it from controller.
configure_dynamic_mode() {
    local controller="${CONTROLLER_HOSTNAME:-}"

    if [[ -z "$controller" ]]; then
        prompt_input "Controller hostname or IP"
        controller="$REPLY"
    fi

    # Ensure controller is resolvable
    ensure_host_resolvable "$controller" "slurmd needs to contact the controller"

    local defaults_file="/etc/default/slurmd"
    local slurmd_opts="--conf-server ${controller}:6817 -Z"

    # Add GPU config if GPUs detected and gres.conf exists
    if [[ "${LOCAL_GPU_COUNT:-0}" -gt 0 ]]; then
        log_info "GPUs detected. Local gres.conf will be used for GPU auto-detection."
        # Note: We don't add --conf "Gres=..." here because gres.conf handles it
    fi

    # Write /etc/default/slurmd
    cat > "$defaults_file" <<EOF
# Configuration for slurmd daemon
# Dynamic mode: fetch config from controller, self-register
SLURMD_OPTIONS="${slurmd_opts}"
EOF

    chmod 0644 "$defaults_file"

    # Remove any existing slurm.conf (configless mode = no local config)
    if [[ -f /etc/slurm/slurm.conf ]]; then
        log_info "Removing local slurm.conf (not needed in dynamic mode)"
        backup_file /etc/slurm/slurm.conf
        rm -f /etc/slurm/slurm.conf
    fi

    log_success "Dynamic mode configured."
    log_info "slurmd will contact ${controller} for configuration."
    log_info "Ensure munge.key is imported before starting slurmd."
}
```

Modify `setup_slurm_conf_compute()`:

```bash
setup_slurm_conf_compute() {
    log_step "Setting up slurm.conf on compute node"

    local conf_file="/etc/slurm/slurm.conf"

    # Check if dynamic mode is available
    if supports_dynamic_nodes; then
        echo
        log_info "This Slurm version supports dynamic node registration."
        log_info "The node can fetch configuration from the controller and self-register."
        echo
        echo -e "  ${BOLD}Dynamic mode benefits:${RESET}"
        echo -e "    - No need to pre-define this node in slurm.conf"
        echo -e "    - No need to distribute slurm.conf to this node"
        echo -e "    - Hardware auto-detected (CPU, RAM) on startup"
        echo
        echo -e "  ${BOLD}Still required:${RESET}"
        echo -e "    - Munge key from controller"
        echo -e "    - Controller must have dynamic mode enabled"
        echo

        menu_select "How would you like to configure this node?" \
            "Dynamic mode — self-register with controller (recommended for Debian 12+)" \
            "Traditional mode — use pre-distributed slurm.conf"

        if [[ "$REPLY" == "1" ]]; then
            configure_dynamic_mode
            DYNAMIC_MODE_ENABLED=true
            return 0
        fi
    fi

    # Traditional mode: existing 4 options
    if [[ -f "$conf_file" ]]; then
        log_info "slurm.conf already exists at ${conf_file}."
        if ! confirm "Overwrite with new configuration?" "default_no"; then
            return 0
        fi
        backup_file "$conf_file"
    fi

    # ... existing menu for traditional mode ...
}
```

Modify `setup_compute()`:

```bash
setup_compute() {
    show_compute_hardware_early
    install_compute_packages
    setup_slurm_conf_compute

    # Dynamic mode: different flow
    if [[ "${DYNAMIC_MODE_ENABLED:-false}" == "true" ]]; then
        # Still need gres.conf for GPU detection (GRES not auto-detected in -Z mode)
        setup_gres_conf_compute

        # Check if munge key exists
        if [[ ! -f /etc/munge/munge.key ]]; then
            log_warn "Munge key not found. Import it before starting slurmd."
            log_info "On the controller, run: ./install.sh --setup-nodes"
            log_info "Or manually copy /etc/munge/munge.key from the controller."
        fi

        detect_hardware
        start_slurmd

        echo
        log_success "Compute node configured in dynamic mode."
        log_info "The node will register with the controller on startup."
        log_info "Run 'sinfo' on the controller to verify it appears."
        return 0
    fi

    # Traditional mode: existing flow
    if [[ "${SLURM_CONF_SKIPPED:-false}" == "true" ]]; then
        log_info "slurmd will not be started until configs are pushed."
        return 0
    fi

    setup_cgroup_conf_compute
    setup_gres_conf_compute
    detect_hardware
    start_slurmd
}
```

### Phase 4: --setup-nodes Changes

**File: `install.sh`**

Add detection and handling:

```bash
# Check if cluster is using dynamic node mode
is_dynamic_mode_enabled() {
    grep -q 'enable_configless' /etc/slurm/slurm.conf 2>/dev/null
}

setup_remote_nodes() {
    log_step "Setting up remote nodes"

    if ! is_controller_node; then
        die "This command must be run on the controller node."
    fi

    if is_dynamic_mode_enabled; then
        setup_remote_nodes_dynamic
    else
        setup_remote_nodes_traditional
    fi
}

# Dynamic mode: only distribute munge key
setup_remote_nodes_dynamic() {
    echo
    log_info "This cluster uses dynamic node discovery."
    log_info "Compute nodes self-register — slurm.conf distribution not needed."
    echo
    log_info "What needs to be distributed:"
    echo -e "  - ${BOLD}munge.key${RESET} (required for authentication)"
    echo
    log_info "What compute nodes handle locally:"
    echo -e "  - slurm.conf (fetched from this controller automatically)"
    echo -e "  - gres.conf (generated during node setup for GPU detection)"
    echo

    # Get list of nodes to configure
    prompt_input "Enter node hostnames (comma or space separated)"
    local nodes_input="$REPLY"

    local nodes
    nodes=$(echo "$nodes_input" | tr ',' '\n' | tr ' ' '\n' | grep -v '^$' | sort -u)

    if [[ -z "$nodes" ]]; then
        log_info "No nodes specified."
        return 0
    fi

    echo
    log_info "Nodes to configure:"
    echo "$nodes" | while read -r node; do
        echo "  - $node"
    done

    select_ssh_mode

    echo
    if ! confirm "Distribute munge.key to these nodes?" "default_yes"; then
        log_info "Cancelled."
        return 0
    fi

    # Test connectivity first
    log_info "Testing SSH connectivity..."
    local ssh_ok=true
    while read -r node; do
        [[ -z "$node" ]] && continue
        if ! test_ssh_connectivity "$node"; then
            ssh_ok=false
        fi
    done <<< "$nodes"

    if ! $ssh_ok; then
        die "Fix SSH connectivity issues and retry."
    fi
    log_success "All nodes reachable."

    # Distribute munge key only
    echo
    local success=0 fail=0
    while read -r node; do
        [[ -z "$node" ]] && continue
        log_info "Distributing munge.key to ${node}..."
        if distribute_munge_key_to_node "$node"; then
            log_success "  ${node} — done"
            ((success++))
        else
            log_error "  ${node} — failed"
            ((fail++))
        fi
    done <<< "$nodes"

    echo
    if [[ $fail -eq 0 ]]; then
        log_success "Munge key distributed to all nodes."
    else
        log_warn "${success} succeeded, ${fail} failed."
    fi

    # Restart local munge
    log_info "Restarting munge on controller..."
    systemctl restart munge
    log_success "Controller munge restarted."

    echo
    log_info "Next steps on each compute node:"
    echo -e "  1. Run: ${CYAN}sudo systemctl restart munge${RESET}"
    echo -e "  2. Run: ${CYAN}sudo systemctl restart slurmd${RESET}"
    echo -e "  3. Verify with: ${CYAN}sinfo${RESET} (on controller)"
}

# Distribute only munge.key to a single node
distribute_munge_key_to_node() {
    local node="$1"
    local ssh_target="${SSH_USER}@${node}"

    case "$SSH_MODE" in
        root)
            ssh_target="root@${node}"
            local_read_file /etc/munge/munge.key | \
                ssh -q -o BatchMode=yes "$ssh_target" \
                "cat > /etc/munge/munge.key && chown munge:munge /etc/munge/munge.key && chmod 0400 /etc/munge/munge.key" \
                2>/dev/null || return 1
            ;;
        sudo_passwordless)
            local_read_file /etc/munge/munge.key | \
                ssh -q -o BatchMode=yes "$ssh_target" \
                "sudo tee /etc/munge/munge.key >/dev/null && sudo chown munge:munge /etc/munge/munge.key && sudo chmod 0400 /etc/munge/munge.key" \
                2>/dev/null || return 1
            ;;
        sudo_password)
            # For password sudo, use existing distribute_to_node_sudo_password approach
            # but only for munge.key
            local local_tmp
            local_tmp=$(mktemp -d)
            trap "rm -rf '$local_tmp'" RETURN
            local_read_file /etc/munge/munge.key > "${local_tmp}/munge.key"

            local ssh_socket="${local_tmp}/ssh-socket"
            local ssh_opts="-o ControlMaster=auto -o ControlPath=${ssh_socket} -o ControlPersist=60"

            log_info "  Connecting (password required)..."
            if ! ssh -q $ssh_opts "$ssh_target" "mkdir -p /tmp/munge-dist.$$" </dev/tty; then
                return 1
            fi

            scp -q $ssh_opts "${local_tmp}/munge.key" "${ssh_target}:/tmp/munge-dist.$$/munge.key" || return 1

            ssh -tt $ssh_opts "$ssh_target" "sudo mv /tmp/munge-dist.$$/munge.key /etc/munge/munge.key && sudo chown munge:munge /etc/munge/munge.key && sudo chmod 0400 /etc/munge/munge.key && rm -rf /tmp/munge-dist.$$" </dev/tty || return 1

            ssh -q -n -o ControlPath="${ssh_socket}" -O exit "$ssh_target" 2>/dev/null || true
            ;;
    esac
    return 0
}

# Traditional mode: existing setup_remote_nodes logic
setup_remote_nodes_traditional() {
    # ... existing code, renamed from setup_remote_nodes ...
}
```

### Phase 5: Template Updates

**File: `config/templates/slurm.conf.tmpl`**

```conf
# ===========================================================================
# slurm.conf — Slurm configuration file
# Generated by slurm-installer on %%GENERATED_DATE%%
# ===========================================================================
# Documentation: https://slurm.schedmd.com/slurm.conf.html
# This file must be identical on ALL nodes in the cluster.
# (In dynamic mode, compute nodes fetch this automatically)
# ===========================================================================

# ── Cluster identity ──────────────────────────────────────────────────────

ClusterName=%%CLUSTER_NAME%%
SlurmctldHost=%%CONTROLLER_HOSTNAME%%

# ── Controller parameters ─────────────────────────────────────────────────
# Dynamic/configless mode settings (if enabled)
%%SLURMCTLD_PARAMETERS%%
%%MAX_NODE_COUNT%%

# ── Daemon paths and users ────────────────────────────────────────────────

SlurmUser=slurm
# ... rest unchanged ...
```

---

## Summary of Changes

| File | Changes |
|------|---------|
| `lib/common.sh` | Add `supports_dynamic_nodes()`, `USE_DYNAMIC_NODES` global |
| `lib/controller.sh` | Add dynamic mode to `generate_slurm_conf()` |
| `lib/compute.sh` | Add `configure_dynamic_mode()`, modify setup flow |
| `install.sh` | Add mode selection, split `--setup-nodes` for dynamic/traditional |
| `config/templates/slurm.conf.tmpl` | Add `%%SLURMCTLD_PARAMETERS%%`, `%%MAX_NODE_COUNT%%` |
| `README.md` | Document dynamic mode, update workflows |
| `CLAUDE.md` | Document new functions and globals |

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Debian 11 controller | Dynamic mode not offered; traditional only |
| Debian 12 controller, Debian 11 compute | Compute uses traditional mode (no -Z support) |
| GPU nodes in dynamic mode | gres.conf still generated locally; GPU detection works |
| Controller-as-compute in dynamic mode | Controller NodeName pre-defined; other nodes dynamic |
| Munge key missing on compute | slurmd fails to start; clear error message |
| Controller unreachable | slurmd fails to start; retry on restart |
| Mixed cluster (some dynamic, some pre-defined) | Works — Nodes=ALL includes both |

---

## Testing Checklist

### Debian 11 (Traditional Mode Only)

- [ ] Controller setup works as before
- [ ] Compute node setup works as before
- [ ] `--setup-nodes` distributes slurm.conf + munge.key
- [ ] No mention of dynamic mode in prompts

### Debian 12+ (Dynamic Mode)

- [ ] Controller prompted for dynamic mode
- [ ] Controller prompted for MaxNodeCount
- [ ] slurm.conf contains `enable_configless` and `MaxNodeCount`
- [ ] slurm.conf contains `Nodes=ALL` partition
- [ ] Compute node offered "Dynamic mode" option
- [ ] Dynamic compute node: no local slurm.conf created
- [ ] Dynamic compute node: `/etc/default/slurmd` has correct options
- [ ] Dynamic compute node starts and registers automatically
- [ ] `sinfo` shows dynamically registered node
- [ ] GPU detection works (gres.conf still used)
- [ ] `--setup-nodes` detects dynamic mode
- [ ] `--setup-nodes` distributes only munge.key in dynamic mode

### Mixed Scenarios

- [ ] Traditional compute node + dynamic controller works
- [ ] Controller-as-compute + dynamic mode works
- [ ] Pre-defined nodes + dynamic nodes coexist

---

## Migration Path

### New Cluster on Debian 12+

Choose dynamic mode during controller setup. All compute nodes use dynamic registration.

### Existing Cluster Upgrading to Dynamic Mode

1. Edit `/etc/slurm/slurm.conf` on controller:
   ```conf
   SlurmctldParameters=enable_configless
   MaxNodeCount=100
   # Change partition to:
   PartitionName=batch Nodes=ALL Default=YES MaxTime=INFINITE State=UP
   ```

2. Run `scontrol reconfigure`

3. Existing pre-defined nodes continue working

4. New nodes can use dynamic registration

### Debian 11 → 12 Upgrade

After OS upgrade, dynamic mode becomes available. Existing traditional config continues to work. New nodes can use dynamic mode.

---

## Future Enhancements

1. **DNS SRV records**: Alternative to `--conf-server` for controller discovery
2. **Node features**: `--conf "Feature=gpu,highmem"` for categorization
3. **Auto munge distribution**: Investigate secure bootstrap without pre-shared key
4. **Cloud integration**: AWS/GCP node provisioning with dynamic registration

---

## References

- [Configless Slurm Documentation](https://slurm.schedmd.com/configless_slurm.html)
- [Dynamic Nodes Documentation](https://slurm.schedmd.com/dynamic_nodes.html)
- [slurmd Manual](https://slurm.schedmd.com/slurmd.html)
- [slurm.conf Reference](https://slurm.schedmd.com/slurm.conf.html)
- [Debian slurm-wlm Package](https://tracker.debian.org/pkg/slurm-wlm)
