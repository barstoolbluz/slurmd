# Slurm Installer for Debian

Interactive, prompt-driven installer for [Slurm Workload Manager](https://slurm.schedmd.com/) on Debian systems (11+).

## Quick start

```bash
sudo ./install.sh
```

The installer walks you through selecting a node role and configuring the cluster. No flags or config files needed upfront.

## Command-line options

| Option | Description |
|--------|-------------|
| `--setup-nodes` | Distribute configs (munge.key, slurm.conf, cgroup.conf) to remote nodes via SSH |
| `--uninstall` | Remove Slurm and MUNGE packages, with options to clean configs and state |
| `--help` | Show usage information |

## Supported node roles

| Role | What it installs | Daemons |
|------|-----------------|---------|
| **Controller + Database** | slurmctld, slurmdbd, MariaDB, MUNGE, client tools | slurmctld, slurmdbd, mariadbd, munged |
| **Controller only** | slurmctld, MUNGE, client tools | slurmctld, munged |
| **Database only** | slurmdbd, MariaDB, MUNGE | slurmdbd, mariadbd, munged |
| **Compute node** | slurmd, MUNGE, client tools | slurmd, munged |
| **Login node** | MUNGE, client tools | munged |

## Cluster setup order

1. **Controller (+ Database)** first — generates the MUNGE key and slurm.conf
2. **Compute nodes** — run `slurmd -C` on each to get hardware lines, add them to slurm.conf on the controller
3. **Distribute configs** to all nodes (choose one method):
   - **Automatic:** `./install.sh --setup-nodes` (requires SSH key auth)
   - **Manual:** Copy `/etc/munge/munge.key`, `/etc/slurm/slurm.conf`, and `/etc/slurm/cgroup.conf` to each node
4. **Database node** (if separate from controller) — run installer before distributing configs
5. **Login nodes** — run installer, then distribute configs
6. On the controller: `scontrol reconfigure` to apply changes

> **Note:** Debian's munge package automatically generates a key during installation if none exists. The installer detects this and prompts before overwriting. On the controller, you typically want to generate a fresh key; on other nodes, you'll import the controller's key.

## Distributing configs with --setup-nodes

After setting up the controller, use `--setup-nodes` to automatically distribute configuration files to all compute and login nodes defined in slurm.conf:

```bash
./install.sh --setup-nodes
```

This will:
- Read node definitions from `/etc/slurm/slurm.conf`
- Copy munge.key, slurm.conf, and cgroup.conf to each node
- Restart munge and slurmd on remote nodes
- Verify munge authentication to each node
- Run `scontrol reconfigure` on the controller

**Requirements:**
- SSH key-based authentication to all nodes
- One of: root SSH access, passwordless sudo, or sudo with password prompt

## Uninstalling

To completely remove Slurm and MUNGE from a node:

```bash
sudo ./install.sh --uninstall
```

You'll be prompted to optionally remove:
- Configuration files (`/etc/slurm`, `/etc/munge`)
- State and log directories (`/var/lib/slurm`, `/var/log/slurm`, `/var/spool/slurm`)
- Slurm database from MariaDB (if applicable)

## Repository layout

```
install.sh              Main entry point (run with sudo)
lib/
  common.sh             Shared functions (logging, prompts, validation)
  prereqs.sh            System prerequisites (NTP, slurm user, directories)
  munge.sh              MUNGE authentication setup
  database.sh           MariaDB + slurmdbd setup
  controller.sh         slurmctld setup
  compute.sh            slurmd setup
  login.sh              Login node setup (client tools only)
config/
  templates/
    slurm.conf.tmpl     slurm.conf template
    slurmdbd.conf.tmpl  slurmdbd.conf template
    cgroup.conf.tmpl    cgroup.conf template
```

## What the installer does

For every role:
- Checks for root and Debian
- Installs chrony (time sync)
- Creates the `slurm` system user/group (UID/GID 64030 by default)
- Creates required directories with correct ownership
- Configures firewall rules (if ufw is active)
- Installs and configures MUNGE authentication
- Installs role-specific Slurm packages
- Generates configuration files from templates
- Starts and enables systemd services
- Runs verification checks

For controller roles with accounting:
- Registers the cluster in the accounting database
- Creates a default "compute" account
- Optionally adds system users to Slurm accounting (enables job submission)

## Configuration files

Generated configs land in `/etc/slurm/`. The installer backs up any existing files before overwriting.

| File | Location | Notes |
|------|----------|-------|
| slurm.conf | `/etc/slurm/slurm.conf` | Must be identical on all nodes |
| slurmdbd.conf | `/etc/slurm/slurmdbd.conf` | Database node only, mode 0600 |
| cgroup.conf | `/etc/slurm/cgroup.conf` | Compute nodes |
| munge.key | `/etc/munge/munge.key` | Must be identical on all nodes |

## Requirements

- Debian 11 (Bullseye), 12 (Bookworm), or 13 (Trixie)
- Root privileges
- Network access to Debian package repositories
- All nodes must be able to reach each other on ports 6817-6819

## Ports

| Port | Service | Direction |
|------|---------|-----------|
| 6817 | slurmctld | Inbound on controller |
| 6818 | slurmd | Inbound on compute nodes |
| 6819 | slurmdbd | Inbound on database node |

## Idempotency

The installer is safe to re-run. It checks current state before acting and prompts before overwriting existing configuration files (with automatic backups).
