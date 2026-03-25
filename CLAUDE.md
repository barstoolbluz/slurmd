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
  controller.sh            # slurmctld setup, slurm.conf generation
  compute.sh               # slurmd setup
  login.sh                 # Client tools only (no daemons)
config/templates/          # Configuration file templates with %%VAR%% placeholders
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
- slurm.conf, cgroup.conf: `0644 root:root` (must be world-readable for sinfo/srun)
- slurmdbd.conf: `0600 slurm:slurm` (contains DB password)
- munge.key: `0400 munge:munge`

### User Prompts
- `confirm "question" "default_yes|default_no"` — returns 0/1
- `prompt_input "label" ["default"]` — result in `$REPLY`
- `menu_select "prompt" "opt1" "opt2"` — result (1-indexed) in `$REPLY`

### Installer State Tracking
Tracks packages installed by the installer (vs. pre-existing) for clean uninstalls:
- State file: `/etc/slurm/.installer-state`
- `record_installed_package "pkg"` — records that we installed a package
- `was_installed_by_us "pkg"` — returns 0 if we installed it, 1 otherwise
- Used for chrony and mariadb-server; uninstall only offers to remove what we installed

### SSH Modes for --setup-nodes
Three modes supported via `SSH_MODE` global:
- `root` — direct root SSH
- `sudo_passwordless` — user SSH + passwordless sudo
- `sudo_password` — user SSH + sudo with password prompt (uses ssh -tt)

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
