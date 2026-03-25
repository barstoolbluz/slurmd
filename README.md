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
| `--setup-nodes` | Distribute configs (munge.key, slurm.conf, cgroup.conf, gres.conf) to remote nodes via SSH |
| `--uninstall` | Remove Slurm and MUNGE packages, with options to clean configs and state |
| `--help` | Show usage information |

## Supported node roles

| Role | What it installs | Daemons |
|------|-----------------|---------|
| **Controller + Database** | slurmctld, slurmdbd, MariaDB*, MUNGE, client tools | slurmctld, slurmdbd, mariadbd/container, munged |
| **Controller only** | slurmctld, MUNGE, client tools | slurmctld, munged |
| **Database only** | slurmdbd, MariaDB*, MUNGE | slurmdbd, mariadbd/container, munged |
| **Compute node** | slurmd, MUNGE, client tools | slurmd, munged |
| **Login node** | MUNGE, client tools | munged |

*MariaDB can be installed natively (Debian package) or run in a Docker/Podman container.

## Cluster setup order

1. **Controller (+ Database)** first — generates the MUNGE key and slurm.conf
2. **Compute nodes** — run `slurmd -C` on each to get hardware lines, add them to slurm.conf on the controller
3. **Distribute configs** to all nodes (choose one method):
   - **Automatic:** `./install.sh --setup-nodes` (requires SSH key auth)
   - **Manual:** Copy `/etc/munge/munge.key`, `/etc/slurm/slurm.conf`, `/etc/slurm/cgroup.conf`, and `/etc/slurm/gres.conf` (if present) to each node
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
- Copy munge.key, slurm.conf, cgroup.conf, and gres.conf (if present) to each node
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
- MariaDB server (if installed by this installer)
- chrony (if installed by this installer)

The installer tracks which packages it installed (vs. pre-existing) in `/etc/slurm/.installer-state`. Only packages the installer actually installed will be offered for removal, ensuring pre-existing services aren't accidentally deleted.

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
    gres.conf.tmpl      gres.conf template (GPU support)
    mariadb-container.service.tmpl  systemd unit for containerized MariaDB
```

## MariaDB: Native vs Container

When installing database roles (Controller + Database or Database only), the installer offers two options for running MariaDB:

### Native (Debian package)

- Uses Debian's `mariadb-server` package
- Integrated with system package management
- Familiar to sysadmins, easy to manage with standard tools
- Automatic security updates via apt

### Container (Docker/Podman)

- Runs MariaDB in an isolated container
- Data persisted in `/var/lib/slurm-mariadb`
- Easy version upgrades (just pull new image)
- Consistent MariaDB version across different Debian releases
- Managed via systemd service `slurm-mariadb`

**Container requirements:**
- Docker (`docker.io` package) or Podman (`podman` package)
- If neither is installed, the installer offers to install one

**Container management:**
```bash
# Check container status
systemctl status slurm-mariadb

# View container logs
docker logs slurm-mariadb   # or: podman logs slurm-mariadb

# Restart the container
systemctl restart slurm-mariadb
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
| gres.conf | `/etc/slurm/gres.conf` | GPU nodes only, auto-generated when NVIDIA or AMD GPUs detected |
| munge.key | `/etc/munge/munge.key` | Must be identical on all nodes |

## Security considerations

### MUNGE key

The MUNGE key (`/etc/munge/munge.key`) is the shared secret for cluster authentication.

- **Permissions:** Must be `0400` owned by `munge:munge`
- **Distribution:** Copy securely (scp, not unencrypted channels)
- **Rotation:** To rotate, generate new key on controller, distribute to all nodes, restart munge everywhere simultaneously

### Database password

The slurmdbd password is stored in `/etc/slurm/slurmdbd.conf`:
- **Permissions:** Must be `0600` owned by `slurm:slurm`
- Auto-generated during installation if not specified
- Only readable by the slurm user (slurmdbd runs as slurm)

### File permissions summary

| File | Permissions | Owner | Why |
|------|-------------|-------|-----|
| munge.key | 0400 | munge:munge | Shared secret, read-only |
| slurm.conf | 0644 | root:root | Must be world-readable for CLI tools |
| slurmdbd.conf | 0600 | slurm:slurm | Contains DB password |
| cgroup.conf | 0644 | root:root | Read by slurmd |
| gres.conf | 0644 | root:root | Read by slurmd for GPU configuration |

## Requirements

- Debian 11 (Bullseye), 12 (Bookworm), or 13 (Trixie)
- Root privileges
- Network access to Debian package repositories
- All nodes must be able to reach each other on ports 6817-6819

## UID/GID consistency

**Critical:** The `slurm` user must have identical UID and GID on ALL cluster nodes.

The installer uses UID/GID 64030 by default. If a node already has a `slurm` user with a different ID, you'll see:

```
[WARN] Existing UID (1001) differs from requested (64030).
[WARN] Ensure this UID is consistent across ALL cluster nodes.
```

### Before installation

Check existing slurm user on all nodes:
```bash
id slurm
```

If IDs differ, either:
1. Use the existing UID/GID on all nodes (enter it during installation)
2. Remove the slurm user and let the installer create it fresh:
   ```bash
   sudo userdel slurm
   sudo groupdel slurm
   ```

### Why this matters

Slurm uses UID/GID for:
- File ownership verification across nodes
- Job credential validation
- Log file access

Mismatched IDs cause authentication failures and permission errors.

## Ports

| Port | Service | Direction |
|------|---------|-----------|
| 6817 | slurmctld | Inbound on controller |
| 6818 | slurmd | Inbound on compute nodes |
| 6819 | slurmdbd | Inbound on database node |

## Idempotency

The installer is safe to re-run. It checks current state before acting and prompts before overwriting existing configuration files (with automatic backups).

## Verifying your cluster

After installation, verify each component:

### Check services
```bash
systemctl status munge slurmctld slurmd slurmdbd mariadb
```

### Test MUNGE authentication
```bash
# Local test
munge -n | unmunge

# Remote test (from controller to compute node)
munge -n | ssh compute01 'unmunge'
```

### Check cluster status
```bash
sinfo                    # All nodes should show 'idle'
scontrol show nodes      # Detailed node information
scontrol show partition  # Partition configuration
```

### Verify accounting (if using slurmdbd)
```bash
sacctmgr show cluster    # Cluster should be registered
sacctmgr show account    # Default 'compute' account
sacctmgr show assoc      # User associations
```

### Submit a test job
```bash
# Interactive single-node test
srun -N1 hostname

# Batch job
sbatch --wrap="echo 'Hello from Slurm'; sleep 5"
squeue                   # Check job status
```

### Multi-node test (if multiple compute nodes)
```bash
srun -N2 hostname        # Should return both hostnames
```

## Common commands

### Cluster status
| Command | Description |
|---------|-------------|
| `sinfo` | Node and partition status |
| `sinfo -N -l` | Detailed node list |
| `squeue` | Job queue |
| `squeue -u $USER` | Your jobs only |
| `scontrol show node <name>` | Node details |
| `scontrol show job <id>` | Job details |

### Job submission
| Command | Description |
|---------|-------------|
| `srun -N1 <cmd>` | Run command on one node |
| `srun -N2 -n4 <cmd>` | Run on 2 nodes, 4 tasks |
| `sbatch script.sh` | Submit batch job |
| `scancel <jobid>` | Cancel a job |

### Accounting (requires slurmdbd)
| Command | Description |
|---------|-------------|
| `sacctmgr show cluster` | Registered clusters |
| `sacctmgr show account` | Accounts |
| `sacctmgr show user` | Users |
| `sacctmgr show assoc` | All associations |
| `sacctmgr add user <name> account=<acct>` | Add user |

### Administration
| Command | Description |
|---------|-------------|
| `scontrol reconfigure` | Reload slurm.conf |
| `scontrol update node=<n> state=resume` | Bring node online |
| `scontrol update node=<n> state=drain reason="maintenance"` | Drain node |

## Adding nodes to an existing cluster

### On the new compute node:

1. Run the installer and select "Compute node"
2. Get the hardware detection line:
   ```bash
   slurmd -C
   ```
   Output example:
   ```
   NodeName=compute02 CPUs=16 RealMemory=64000 Sockets=1 CoresPerSocket=8 ThreadsPerCore=2 State=UNKNOWN
   ```

### On the controller:

1. Add the NodeName line to `/etc/slurm/slurm.conf`
2. Add the node to the partition (e.g., `Nodes=compute01,compute02`)
3. Distribute the updated config:
   ```bash
   ./install.sh --setup-nodes
   ```
   Or manually copy slurm.conf to the new node.

4. Reconfigure the controller:
   ```bash
   scontrol reconfigure
   ```

5. Verify the node appears:
   ```bash
   sinfo
   ```

> **Note:** Node ranges like `compute[01-10]` in slurm.conf are supported, but `--setup-nodes` can only distribute to explicitly named nodes. Ranges require manual distribution.

## Controller as compute node

For small clusters, the controller can also run jobs. During installation, when prompted to define compute nodes, you can include the controller itself. The installer will ask:

```
Add THIS machine (controller01) as a compute node? [y/N]
```

Answer `y` to enable this.

This will:
- Add the controller's NodeName line to slurm.conf
- Install slurmd alongside slurmctld
- Start both daemons

The controller will appear in `sinfo` as both the controller and an available compute node.

> **Caution:** For production clusters, keep controller and compute roles separate. Running jobs on the controller can impact scheduling performance.

## GPU support

The installer automatically detects NVIDIA and AMD GPUs and configures Slurm for GPU scheduling.

### How it works

1. During hardware detection, `nvidia-smi` and `rocm-smi` are queried to count GPUs
2. If GPUs are found, `Gres=gpu:N` is added to the NodeName line (total of all GPUs)
3. On GPU nodes, `/etc/slurm/gres.conf` is generated with `AutoDetect=any`
4. When any compute node has GPUs, `GresTypes=gpu` is enabled in slurm.conf

### Requirements

- **NVIDIA:** NVIDIA drivers installed and working (`nvidia-smi` must be functional)
- **AMD:** ROCm drivers installed and working (`rocm-smi` must be functional)
- No manual GPU configuration needed — auto-detection handles all GPUs

### Verifying GPU configuration

```bash
# Check if GPUs are detected
nvidia-smi       # NVIDIA
rocm-smi --showid  # AMD

# View GRES in slurm.conf
grep -E 'GresTypes|Gres=' /etc/slurm/slurm.conf

# Check gres.conf
cat /etc/slurm/gres.conf

# Show GPU resources in cluster
sinfo -o "%N %G"
```

### Submitting GPU jobs

```bash
# Request 1 GPU
srun --gres=gpu:1 nvidia-smi

# Request 2 GPUs
sbatch --gres=gpu:2 myjob.sh
```

### Mixed clusters (GPU + non-GPU nodes)

The installer handles mixed clusters automatically:
- `GresTypes=gpu` is enabled cluster-wide when any node has GPUs
- Only GPU nodes include `Gres=gpu:N` in their NodeName definition
- Only GPU nodes get a `gres.conf` file
- Non-GPU nodes work normally without any GPU configuration

## Troubleshooting

### Nodes showing as DOWN or NOT_RESPONDING

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `down*` in sinfo | MUNGE key mismatch | Ensure identical key on all nodes, restart munge everywhere |
| `NOT_RESPONDING` | Hostname not resolvable | Add controller to `/etc/hosts` on compute nodes |
| Node not appearing | Not in slurm.conf | Add NodeName line, run `scontrol reconfigure` |

### MUNGE authentication failures

- Check key permissions: `stat /etc/munge/munge.key` (should be 0400 munge:munge)
- Test locally: `munge -n | unmunge`
- Test remotely: `munge -n | ssh compute01 'unmunge'`
- Check logs: `journalctl -xeu munge`

### Jobs stuck in pending

- Verify user has accounting association: `sacctmgr show assoc user=$USER`
- Check node state: `sinfo` (nodes must be `idle`, not `down` or `drain`)
- Verify partition exists: `scontrol show partition`

### Service won't start

For any service (munge, slurmd, slurmctld, slurmdbd):
```bash
systemctl status <service>
journalctl -xeu <service>
```

Common causes:
- **munge**: Wrong key permissions, /etc/munge not owned by munge
- **slurmd**: Can't reach controller, slurm.conf mismatch
- **slurmctld**: Port 6817 in use, invalid slurm.conf syntax
- **slurmdbd**: MariaDB not running, wrong DB password in slurmdbd.conf

### Permission denied running sinfo/srun

slurm.conf must be world-readable (0644). Fix:
```bash
sudo chmod 0644 /etc/slurm/slurm.conf
```

### GPU jobs fail or GPUs not visible

| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| `srun --gres=gpu:1` fails immediately | `GresTypes=gpu` not in slurm.conf | Add `GresTypes=gpu` to slurm.conf, run `scontrol reconfigure` |
| GPUs not showing in `sinfo -o "%G"` | Node missing `Gres=gpu:N` | Add `Gres=gpu:N` to NodeName line in slurm.conf |
| Job runs but GPUs not visible | Missing gres.conf | Create `/etc/slurm/gres.conf` with `AutoDetect=any` |
| `nvidia-smi`/`rocm-smi` works but Slurm doesn't see GPUs | Auto-detection failed | Check that the tool runs as slurm user: `sudo -u slurm nvidia-smi` |

## Known limitations

This installer provides a straightforward single-cluster setup. Feature support:

| Feature | Status | Notes |
|---------|--------|-------|
| NVIDIA GPU scheduling | Supported | Auto-detected via nvidia-smi, uses NVML |
| AMD GPU scheduling | Supported | Auto-detected via rocm-smi, uses RSMI |
| Intel GPUs | Not supported | No auto-detection support |
| High availability | Not supported | Single controller only, no failover |
| Federation | Not supported | Single cluster only |
| Non-Debian distros | Not supported | Debian 11, 12, 13 only |
| Node ranges in --setup-nodes | Partial | Must distribute to ranges manually |
| Dynamic node discovery | Not supported | Nodes must be added to slurm.conf manually |
| Encrypted communication | Not supported | MUNGE provides authentication, not encryption |
| Shared filesystem | Not configured | No NFS/Lustre integration |

For advanced configurations, refer to the [Slurm documentation](https://slurm.schedmd.com/documentation.html).
