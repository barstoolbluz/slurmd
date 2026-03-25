# CLAUDE.md

## Project Overview

Interactive Slurm Workload Manager installer for Debian systems. Provides a prompt-driven CLI to install and configure Slurm clusters with support for multiple node roles.

## Architecture

```
install.sh                 # Main entry point, CLI parsing, orchestration
lib/
  common.sh                # Shared utilities (logging, prompts, validation, templates)
  prereqs.sh               # System setup (chrony, slurm user, directories, firewall)
  munge.sh                 # MUNGE authentication (key generation/import)
  database.sh              # MariaDB + slurmdbd setup
  controller.sh            # slurmctld setup, slurm.conf generation, gres.conf generation
  compute.sh               # slurmd setup, gres.conf generation
  login.sh                 # Client tools only (no daemons)
config/templates/          # Configuration file templates with %%VAR%% placeholders
                           # Note: gres.conf is generated dynamically, not from template
```

## Key Patterns

### Bash Style
- `set -euo pipefail` in all scripts
- Functions use `local` for all variables
- Error handling: `command || { log_error "msg"; return 1; }`
- All scripts are sourced by install.sh, not executed directly

### Template Rendering
Templates use `%%VARIABLE%%` placeholders, rendered by `render_template()` in common.sh:
```bash
declare -A vars=( [KEY]="value" )
render_template "$template" "$output_file" vars
```

### File Permissions
- slurm.conf, cgroup.conf, gres.conf: `0644 root:root` (must be world-readable for sinfo/srun)
- slurmdbd.conf: `0600 slurm:slurm` (contains DB password)
- munge.key: `0400 munge:munge`

### MUNGE Key Import
For non-controller nodes, `import_munge_key()` in munge.sh offers three methods:
1. **Fetch from controller via SSH** (recommended) — `fetch_munge_key_from_controller()` uses SSH+sudo to retrieve the key, with base64 encoding to handle binary transfer safely
2. **Path to local file** — user pre-copies the key via scp
3. **Paste base64** — user runs `sudo base64 /etc/munge/munge.key` on controller and pastes output

### User Prompts
- `confirm "question" "default_yes|default_no"` — returns 0/1
- `prompt_input "label" ["default"]` — result in `$REPLY`
- `menu_select "prompt" "opt1" "opt2"` — result (1-indexed) in `$REPLY`

### Installer State Tracking
Tracks packages installed by the installer (vs. pre-existing) for clean uninstalls:
- State file: `/etc/slurm/.installer-state`
- `record_installed_package "pkg"` — records that we installed a package
- `was_installed_by_us "pkg"` — returns 0 if we installed it, 1 otherwise
- Tracked packages: `chrony`, `mariadb-server`, `mariadb-container`
- Uninstall only offers to remove what we installed

### Container Runtime
Support for Docker and Podman (prefers Podman if both available):
- `detect_container_runtime()` — sets `CONTAINER_RUNTIME` global to "podman" or "docker"
- `has_container_runtime()` — returns 0 if a runtime is available
- `container_exists "name"` — checks if container exists
- `container_is_running "name"` — checks if container is running

### MariaDB Container Option
Database roles offer native or containerized MariaDB:
- `USE_MARIADB_CONTAINER` global in database.sh controls the path
- `choose_mariadb_method()` — prompts user, sets the global
- Container uses systemd service `slurm-mariadb` (template: `mariadb-container.service.tmpl`)
- Data persisted in `/var/lib/slurm-mariadb`
- slurmdbd.service gets a drop-in dependency on slurm-mariadb.service when using container

### SSH Modes for --setup-nodes
Three modes supported via `SSH_MODE` global:
- `root` — direct root SSH
- `sudo_passwordless` — user SSH + passwordless sudo
- `sudo_password` — user SSH + sudo with password prompt (uses ssh -tt)

### Adding Compute Nodes After Installation
If compute nodes are skipped during initial setup, `--setup-nodes` can add them later:
- `is_controller_node()` — checks if slurmctld service exists
- `add_nodes_to_slurm_conf()` — adds NodeName lines to existing slurm.conf
- When `--setup-nodes` finds no nodes, it offers to add them via `gather_compute_nodes()`
- Automatically updates partition definitions and enables GresTypes if GPUs detected

### GPU Detection
NVIDIA and AMD GPUs are auto-detected:
- `detect_nvidia_gpus()` in common.sh sets `LOCAL_NVIDIA_GPU_COUNT` and `LOCAL_HAS_NVIDIA` via `nvidia-smi`
- `detect_amd_gpus()` in common.sh sets `LOCAL_AMD_GPU_COUNT` and `LOCAL_HAS_AMD` via `rocm-smi`
- Both called automatically by `detect_local_hardware()`, which computes `LOCAL_GPU_COUNT` as the total
- `format_nodename_line()` adds `Gres=gpu:N` when any GPUs detected (combined count)
- `generate_gres_conf()` (controller.sh) / `setup_gres_conf_compute()` (compute.sh) dynamically generate gres.conf
- gres.conf is NOT templated — it's generated based on which GPU plugins are installed:
  - `slurm-wlm-nvml-plugin` for NVIDIA (from Debian contrib repository)
  - `slurm-wlm-rsmi-plugin` for AMD (from Debian contrib repository)
- Only includes `AutoDetect=nvml` or `AutoDetect=rsmi` for plugins that are actually installed
- `GresTypes=gpu` added to slurm.conf when any compute node has GPUs

### Controller-as-Compute
A controller can also run jobs as a compute node (common for small clusters):
- Dedicated prompt: "Should this controller ALSO act as a compute node?" appears after UID/GID setup
- If yes: auto-detects hardware, stores result in `CONTROLLER_NODENAME`
- `CONTROLLER_IS_COMPUTE` flag triggers slurmd installation on controllers
- `gather_compute_nodes()` automatically includes `CONTROLLER_NODENAME` in the node list
- This is separate from the "Define additional compute nodes now?" prompt

### Service Defaults Files
Debian's Slurm systemd units reference `$*_OPTIONS` environment variables that cause
warnings if undefined. The installer creates `/etc/default/{slurmd,slurmctld,slurmdbd}`:
- `setup_service_defaults()` in common.sh creates the file if it doesn't exist
- Called from `start_slurmd()`, `start_slurmctld()`, `start_slurmdbd()` before starting each service
- Files are not overwritten if they already exist (preserves user customizations)
- Users can add options like `-D -vvv` for debug mode

## Node Roles

| Role | Variable | Installs |
|------|----------|----------|
| Controller + DB | `controller_db` | slurmctld, slurmdbd, MariaDB, munge |
| Controller only | `controller` | slurmctld, munge |
| Database only | `database` | slurmdbd, MariaDB, munge |
| Compute | `compute` | slurmd, munge |
| Login | `login` | slurm-client, munge |

## Testing Changes

No test suite. Validate with:
```bash
bash -n install.sh
bash -n lib/*.sh
```

For regex patterns, test with representative inputs:
```bash
echo "SlurmctldHost=ctrl01(backup)" | grep -oP '^SlurmctldHost=\K[^(\s]+'
```

## Common Gotchas

1. **Permissions**: slurm.conf must be 0644 (not 0640) or regular users can't run sinfo/srun
2. **Munge key sync**: After distributing keys, munge must be restarted on ALL nodes
3. **Hostname resolution**: Compute nodes need to resolve the controller hostname
4. **Accounting**: Users must be added to slurmdbd via sacctmgr before they can submit jobs
5. **Variable shadowing**: Don't use `hostname` as a variable name (shadows the command)

## Commit Style

Follow existing pattern:
```
Short summary line (imperative mood)

Optional longer description with:
- Bullet points for multiple changes
- Context on why, not just what

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
```
