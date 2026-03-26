# Plan: Dynamic Node Discovery (Configless Slurm)

## Overview

Implement Slurm's "configless" mode for Debian 12+ systems, dramatically simplifying compute node setup while maintaining the current manual workflow for Debian 11.

**Current workflow (manual):**
1. Install slurmd on compute node
2. Run `slurmd -C` to get hardware line
3. Send NodeName line to cluster admin
4. Admin adds line to slurm.conf on controller
5. Admin runs `--setup-nodes` to distribute slurm.conf back to compute node
6. Start slurmd

**New workflow (configless, Debian 12+):**
1. Install slurmd on compute node
2. Configure minimal slurm.conf with just `SlurmctldHost=<controller>`
3. Import munge.key from controller
4. Start slurmd → automatically registers with controller

---

## Slurm Version Requirements

| Feature | Minimum Version | Debian Availability |
|---------|-----------------|---------------------|
| Configless Slurm | 20.02 | Debian 11 (20.11), 12 (22.05), 13 (24.x) |
| Dynamic Nodes | 22.05 | Debian 12+, 13 |
| Full Dynamic Partitions | 23.02 | Debian 13 only |

**Decision:** Target Debian 12+ for dynamic mode since it has full dynamic node support (22.05+). Debian 11 has configless but not dynamic nodes, which would create a confusing half-measure.

---

## Architecture Analysis

### Current Code Structure

```
install.sh
├── collect_config()          # Gathers COMPUTE_NODES from user input
├── gather_compute_nodes()    # Interactive NodeName entry
├── setup_remote_nodes()      # --setup-nodes entry point
│   ├── distribute_to_node()  # Pushes slurm.conf to nodes
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
# Dynamic node mode (set based on Debian version)
USE_DYNAMIC_NODES=false

# Check if dynamic nodes are supported
supports_dynamic_nodes() {
    [[ "${DEBIAN_VERSION:-0}" -ge 12 ]]
}
```

**File: `install.sh`**

In `collect_config()`, for controller roles, add mode selection after version check:

```bash
case "$NODE_ROLE" in
    controller|controller_db)
        if supports_dynamic_nodes; then
            echo
            log_info "Slurm ${SLURM_VERSION} supports dynamic node discovery."
            log_info "Compute nodes can self-register without pre-configuration."

            if confirm "Enable dynamic node discovery? (recommended)" "default_yes"; then
                USE_DYNAMIC_NODES=true
                log_success "Dynamic mode enabled. Compute nodes will auto-register."
            else
                log_info "Using traditional mode. Nodes must be pre-defined in slurm.conf."
            fi
        fi
        ;;
esac
```

### Phase 2: Controller Changes

**File: `lib/controller.sh`**

Modify `generate_slurm_conf()` to handle dynamic mode:

```bash
generate_slurm_conf() {
    # ... existing setup ...

    # Build node definitions based on mode
    local node_defs=""
    local partition_defs=""
    local slurmctld_params=""

    if [[ "${USE_DYNAMIC_NODES:-false}" == "true" ]]; then
        # Dynamic mode: enable configless, use Nodes=ALL
        slurmctld_params="SlurmctldParameters=enable_configless"
        node_defs="# Dynamic node mode: nodes self-register, no pre-definition needed"
        partition_defs="PartitionName=${PARTITION_NAME:-batch} Nodes=ALL Default=YES MaxTime=INFINITE State=UP"

        # Still include controller if it's also a compute node
        if [[ -n "${CONTROLLER_NODENAME:-}" ]]; then
            node_defs="${node_defs}"$'\n'"# Controller node (also runs jobs):"
            node_defs="${node_defs}"$'\n'"${CONTROLLER_NODENAME}"
        fi
    else
        # Traditional mode: existing logic
        if [[ -n "${COMPUTE_NODES:-}" ]]; then
            node_defs="$COMPUTE_NODES"
            local node_names
            node_names=$(echo "$COMPUTE_NODES" | grep -oP 'NodeName=\K[^\s]+' | paste -sd',' -)
            partition_defs="PartitionName=${PARTITION_NAME:-batch} Nodes=${node_names} Default=YES MaxTime=INFINITE State=UP"
        else
            node_defs="# No compute nodes configured yet."
            # ... existing placeholder text ...
        fi
    fi

    # Add to template vars
    declare -A vars=(
        # ... existing vars ...
        [SLURMCTLD_PARAMETERS]="${slurmctld_params}"
        [NODE_DEFINITIONS]="${node_defs}"
        [PARTITION_DEFINITIONS]="${partition_defs}"
    )
    # ...
}
```

**File: `config/templates/slurm.conf.tmpl`**

Add placeholder for SlurmctldParameters:

```conf
# ── Controller parameters ────────────────────────────────────────────────
%%SLURMCTLD_PARAMETERS%%
```

### Phase 3: Compute Node Changes

**File: `lib/compute.sh`**

Add new minimal config option for dynamic mode:

```bash
# Generate minimal slurm.conf for configless mode.
# Only needs SlurmctldHost - everything else fetched from controller.
generate_minimal_slurm_conf() {
    local conf_file="/etc/slurm/slurm.conf"
    local controller="${CONTROLLER_HOSTNAME:-}"

    if [[ -z "$controller" ]]; then
        prompt_input "Controller hostname or IP"
        controller="$REPLY"
    fi

    cat > "$conf_file" <<EOF
# Minimal slurm.conf for configless mode
# Full configuration fetched automatically from controller
SlurmctldHost=${controller}
EOF

    chown root:root "$conf_file"
    chmod 0644 "$conf_file"

    log_success "Minimal slurm.conf written (configless mode)."
    log_info "Full configuration will be fetched from ${controller} on startup."
}
```

Modify `setup_slurm_conf_compute()` to offer dynamic mode when supported:

```bash
setup_slurm_conf_compute() {
    log_step "Setting up slurm.conf on compute node"

    local conf_file="/etc/slurm/slurm.conf"

    # Check if dynamic mode is available
    if supports_dynamic_nodes; then
        echo
        log_info "This Slurm version supports configless mode."
        log_info "The compute node can fetch its configuration automatically from the controller."
        echo

        menu_select "How would you like to configure this node?" \
            "Configless mode — fetch config from controller automatically (recommended)" \
            "Traditional mode — provide slurm.conf manually"

        if [[ "$REPLY" == "1" ]]; then
            generate_minimal_slurm_conf
            CONFIGLESS_MODE=true
            return 0
        fi
    fi

    # Traditional mode: existing 4 options
    # ... existing code ...
}
```

Modify `setup_compute()` to handle configless mode:

```bash
setup_compute() {
    show_compute_hardware_early
    install_compute_packages
    setup_slurm_conf_compute

    # Configless mode: slurmd fetches config on start, no need for local cgroup.conf
    if [[ "${CONFIGLESS_MODE:-false}" == "true" ]]; then
        setup_gres_conf_compute  # Still need local gres.conf for GPU detection
        start_slurmd

        echo
        log_success "Compute node configured in configless mode."
        log_info "The node will automatically register with the controller."
        log_info "Run 'sinfo' on the controller to verify it appears."
        return 0
    fi

    # Traditional mode: existing flow
    # ...
}
```

### Phase 4: --setup-nodes Changes

**File: `install.sh`**

Modify `setup_remote_nodes()` to detect dynamic mode from slurm.conf:

```bash
# Check if cluster is using dynamic node mode
is_dynamic_mode() {
    grep -q 'enable_configless' /etc/slurm/slurm.conf 2>/dev/null
}

setup_remote_nodes() {
    log_step "Setting up remote nodes"

    if is_dynamic_mode; then
        echo
        log_info "This cluster uses dynamic node discovery."
        log_info "Compute nodes auto-register — no slurm.conf distribution needed."
        echo
        log_info "To add a new compute node:"
        echo -e "  1. Run the installer on the compute node"
        echo -e "  2. Select 'Configless mode' when prompted"
        echo -e "  3. Import the munge key from this controller"
        echo -e "  4. The node will appear automatically in 'sinfo'"
        echo

        if confirm "Distribute munge.key to nodes?" "default_yes"; then
            # Only distribute munge key, not slurm.conf
            distribute_munge_key_only
        fi
        return 0
    fi

    # Traditional mode: existing --setup-nodes logic
    # ...
}
```

Add munge-key-only distribution:

```bash
distribute_munge_key_only() {
    echo
    prompt_input "Enter node hostnames (comma or space separated)"
    local nodes_input="$REPLY"

    # Parse into newline-separated list
    local nodes
    nodes=$(echo "$nodes_input" | tr ',' '\n' | tr ' ' '\n' | grep -v '^$')

    select_ssh_mode

    # Distribute munge key to each node
    while read -r node; do
        [[ -z "$node" ]] && continue
        log_info "Distributing munge.key to ${node}..."
        # ... distribution logic (existing scp/ssh code, just for munge.key)
    done <<< "$nodes"
}
```

### Phase 5: Template Updates

**File: `config/templates/slurm.conf.tmpl`**

```conf
# ── Cluster identity ──────────────────────────────────────────────────────

ClusterName=%%CLUSTER_NAME%%
SlurmctldHost=%%CONTROLLER_HOSTNAME%%

# ── Controller parameters ─────────────────────────────────────────────────
%%SLURMCTLD_PARAMETERS%%

# ... rest of template ...
```

---

## Migration Path

### Upgrading Debian 11 → 12

If a cluster upgrades from Debian 11 to 12:

1. Existing slurm.conf without `enable_configless` continues to work
2. Admin can choose to enable dynamic mode:
   ```bash
   # Add to slurm.conf on controller
   SlurmctldParameters=enable_configless

   # Change partition to accept dynamic nodes
   PartitionName=batch Nodes=ALL ...

   # Restart slurmctld
   systemctl restart slurmctld
   ```
3. New compute nodes use configless mode
4. Existing compute nodes continue working (pre-defined in slurm.conf)

### Mixed Clusters

A cluster can have both:
- Pre-defined nodes (NodeName lines in slurm.conf)
- Dynamic nodes (self-registered via configless)

Both work simultaneously with `Nodes=ALL` partition.

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| Debian 11 controller, Debian 12 compute | Traditional mode only (controller doesn't support dynamic) |
| Debian 12 controller, Debian 11 compute | Works - compute node uses configless even though Slurm 20.11 |
| GPU nodes in dynamic mode | gres.conf still generated locally; GPU detection works |
| Controller-as-compute in dynamic mode | Controller NodeName pre-defined; other nodes dynamic |
| Munge key mismatch | Node fails to register (same as current behavior) |
| Network partition | Node goes to DOWN state, recovers when reconnected |

---

## Files Modified

| File | Changes |
|------|---------|
| `lib/common.sh` | Add `supports_dynamic_nodes()`, `USE_DYNAMIC_NODES` global |
| `lib/controller.sh` | Modify `generate_slurm_conf()` for dynamic mode |
| `lib/compute.sh` | Add `generate_minimal_slurm_conf()`, modify setup flow |
| `install.sh` | Add mode selection in `collect_config()`, modify `--setup-nodes` |
| `config/templates/slurm.conf.tmpl` | Add `%%SLURMCTLD_PARAMETERS%%` placeholder |
| `README.md` | Document dynamic mode, update workflows |
| `CLAUDE.md` | Document new functions and globals |

---

## Testing Checklist

### Debian 11 (Traditional Mode Only)

- [ ] Controller setup works as before
- [ ] Compute node setup works as before
- [ ] `--setup-nodes` works as before
- [ ] No mention of dynamic mode in prompts

### Debian 12+ (Dynamic Mode)

- [ ] Controller prompted for dynamic mode
- [ ] Dynamic mode enabled: `enable_configless` in slurm.conf
- [ ] Dynamic mode enabled: `Nodes=ALL` in partition
- [ ] Compute node offered "Configless mode" option
- [ ] Configless compute node generates minimal slurm.conf
- [ ] Configless compute node starts and registers automatically
- [ ] `sinfo` shows dynamically registered node
- [ ] GPU detection works in dynamic mode
- [ ] `--setup-nodes` detects dynamic mode and offers munge-only distribution

### Mixed Scenarios

- [ ] Traditional compute node + dynamic controller works
- [ ] Controller-as-compute + dynamic mode works
- [ ] Existing pre-defined nodes + new dynamic nodes coexist

---

## Future Enhancements

1. **Auto munge key distribution**: Use `SrunPortRange` and encrypted channels for keyless bootstrap
2. **Node features**: Support `Features=` for dynamic node categorization
3. **Weight-based scheduling**: Auto-assign weights based on hardware
4. **Cloud integration**: AWS/GCP node provisioning with dynamic registration

---

## References

- [Slurm Configless Documentation](https://slurm.schedmd.com/configless_slurm.html)
- [Dynamic Nodes (Slurm 22.05+)](https://slurm.schedmd.com/dynamic_nodes.html)
- [SlurmctldParameters](https://slurm.schedmd.com/slurm.conf.html#OPT_SlurmctldParameters)
