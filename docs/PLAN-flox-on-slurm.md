# Plan: Running Flox Environments on Slurm Compute Nodes

## Goal

Enable Slurm users to submit jobs that run inside Flox environments on compute
nodes, providing reproducible, declarative dependency management for HPC workloads.

## Assumptions

- Controller node is already running (this machine)
- Compute nodes are Debian-based, reachable via SSH from the controller
- No shared filesystem is assumed (the installer distributes files via SCP)
- Flox is already installed on the controller

## Architecture Overview

```
Controller (this node)
├── Flox installed
├── /nix/store (local)
├── Environments authored here or pulled from FloxHub
│
├── Option A: NFS-export /nix to compute nodes (recommended for clusters with shared storage)
│   └── Compute nodes mount /nix read-only — no per-node package downloads
│
└── Option B: Flox installed independently on each compute node (no shared storage)
    └── Each node pulls environments from FloxHub on first use — higher disk/bandwidth cost
```

Choose **one** of Option A or Option B based on whether you have or want shared storage.

---

## Phase 1: Install Flox on Compute Nodes

### 1.1 Install Flox on the controller (if not already)

```bash
curl -fsSL https://install.flox.dev | bash
flox --version
```

### 1.2 Install Flox on each compute node

SSH to each compute node and run the installer. You can use the same SSH mode
your Slurm installer uses (root, sudo_passwordless, sudo_password).

**One node at a time (manual):**

```bash
ssh root@compute01 'curl -fsSL https://install.flox.dev | bash'
```

**All nodes via a loop (using hostnames from slurm.conf):**

```bash
# Extract compute node hostnames from slurm.conf
NODES=$(grep -oP '^NodeName=\K[^\s]+' /etc/slurm/slurm.conf | tr ',' '\n')

for node in $NODES; do
    echo "=== Installing Flox on $node ==="
    ssh root@"$node" 'curl -fsSL https://install.flox.dev | bash' || {
        echo "FAILED: $node"
        continue
    }
    echo "OK: $node"
done
```

For sudo-based SSH, adjust accordingly:

```bash
ssh -t user@"$node" 'curl -fsSL https://install.flox.dev | sudo bash'
```

### 1.3 Verify Flox is available on compute nodes

```bash
for node in $NODES; do
    echo -n "$node: "
    ssh root@"$node" 'flox --version'
done
```

---

## Phase 2: Choose a /nix/store Strategy

### Option A: Shared /nix/store via NFS (recommended)

This avoids duplicating packages across nodes. All nodes share the controller's
Nix store.

**On the controller (NFS server):**

```bash
# Install NFS server if not present
apt-get install -y nfs-kernel-server

# Export /nix read-only to compute nodes
# Adjust the network/hostnames to match your cluster
echo '/nix  192.168.1.0/24(ro,no_root_squash,no_subtree_check)' >> /etc/exports
exportfs -ra
systemctl restart nfs-kernel-server
```

**On each compute node (NFS client):**

```bash
apt-get install -y nfs-common

# Back up the local /nix if it exists from the Flox install
# (The Flox binary itself lives in /usr/local or similar, not /nix)
mv /nix /nix.local.bak 2>/dev/null || true

# Mount the controller's /nix
mkdir -p /nix
echo 'controller:/nix  /nix  nfs  ro,hard,intr  0  0' >> /etc/fstab
mount /nix
```

Replace `controller` with the actual hostname or IP of your controller node.

**Verify:**

```bash
ssh root@compute01 'ls /nix/store | head -5'
```

> **Note:** With NFS-shared /nix, environments built or pulled on the controller
> are instantly available on all compute nodes. No `flox pull` needed on each node.

### Option B: Independent /nix/store per Node (no NFS)

Each compute node maintains its own /nix/store. Environments are pulled from
FloxHub on first activation and cached locally.

**Pros:** No shared storage dependency, nodes are fully independent.
**Cons:** First activation on each node downloads all packages. More disk usage.

No additional setup beyond Phase 1 — Flox installs its own /nix/store.

To pre-warm a node's cache (optional):

```bash
ssh root@compute01 'flox activate -r youruser/my-env -- true'
```

---

## Phase 3: Create and Publish a Flox Environment

You need an environment that compute nodes can activate. Two approaches:

### 3a. FloxHub Remote Environments (works with both Options A and B)

Create and push an environment from the controller:

```bash
mkdir -p ~/flox-envs/my-hpc-stack && cd ~/flox-envs/my-hpc-stack
flox init
flox install python311Full uv gcc cmake   # whatever your workload needs
flox activate -- python3 --version        # verify it works

# Push to FloxHub (requires flox auth login first)
git init && git add -A && git commit -m "Initial environment"
# Add a remote, then:
flox push
```

Users reference it in jobs as `flox activate -r youruser/my-hpc-stack -- ...`

### 3b. Project-Local Environments (best with Option A / NFS)

If your project directory lives on shared storage, the `.flox/` directory is
already accessible to all nodes:

```bash
cd /shared/projects/my-project
flox init
flox install python311Full numpy
# .flox/ is visible to all nodes via NFS
```

Jobs `cd` to the project and activate directly. With NFS-shared /nix, the
packages referenced by `.flox/` are already in the shared store.

### 3c. Local Environments Distributed via SCP (no FloxHub, no NFS)

If you don't want to use FloxHub and don't have shared storage, you can
distribute `.flox/` directories to each node:

```bash
# On controller
cd /path/to/project
tar czf /tmp/flox-env.tar.gz .flox/

# Distribute
for node in $NODES; do
    scp /tmp/flox-env.tar.gz root@"$node":/path/to/project/
    ssh root@"$node" "cd /path/to/project && tar xzf flox-env.tar.gz && rm flox-env.tar.gz"
done
```

> This is the least convenient option. Prefer FloxHub or NFS.

---

## Phase 4: Submit Slurm Jobs Using Flox

### 4.1 Basic Job Script

Create `job.sh`:

```bash
#!/bin/bash
#SBATCH --job-name=flox-test
#SBATCH --output=flox-test-%j.out
#SBATCH --nodes=1
#SBATCH --ntasks=1

# Activate a remote FloxHub environment and run a command
flox activate -r youruser/my-hpc-stack -- python3 -c "
import sys
print(f'Python {sys.version}')
print(f'Running on {__import__(\"socket\").gethostname()}')
"
```

Submit:

```bash
sbatch job.sh
```

### 4.2 Multi-Line Job with Flox

For more complex jobs, use a wrapper script or heredoc:

```bash
#!/bin/bash
#SBATCH --job-name=training
#SBATCH --output=train-%j.out
#SBATCH --gres=gpu:1

# Create a temporary script with the actual work
cat > /tmp/slurm-work-$SLURM_JOB_ID.sh << 'WORK'
#!/bin/bash
set -euo pipefail
echo "Python: $(python3 --version)"
echo "Working dir: $(pwd)"
cd "$SLURM_SUBMIT_DIR"
python3 train.py --epochs 100
WORK
chmod +x /tmp/slurm-work-$SLURM_JOB_ID.sh

flox activate -r youruser/ml-stack -- /tmp/slurm-work-$SLURM_JOB_ID.sh
rm -f /tmp/slurm-work-$SLURM_JOB_ID.sh
```

### 4.3 Project-Local Environment (shared storage)

```bash
#!/bin/bash
#SBATCH --job-name=analysis
#SBATCH --output=analysis-%j.out

cd /shared/projects/my-project
flox activate -- python3 analyze.py
```

### 4.4 GPU Job with CUDA Flox Environment

```bash
#!/bin/bash
#SBATCH --job-name=gpu-train
#SBATCH --gres=gpu:1
#SBATCH --partition=gpu

flox activate -r youruser/cuda-ml-stack -- python3 train_gpu.py
```

---

## Phase 5: Optional Enhancements

### 5.1 Slurm Prolog — Pre-Cache Environments

Add a prolog script so environments are warm before jobs start. This avoids
first-run download latency inside job time.

Create `/etc/slurm/prolog.d/flox-cache.sh`:

```bash
#!/bin/bash
# Pre-cache Flox environment if SLURM_FLOX_ENV is set
if [ -n "${SLURM_FLOX_ENV:-}" ]; then
    flox activate -r "$SLURM_FLOX_ENV" -- true 2>/dev/null || true
fi
```

Add to slurm.conf on the controller:

```
PrologSlurmctld=/etc/slurm/prolog.d/flox-cache.sh
```

Or for compute-node-side prolog:

```
Prolog=/etc/slurm/prolog.d/flox-cache.sh
```

Distribute slurm.conf and the prolog script, then `scontrol reconfigure`.

Users submit with:

```bash
sbatch --export=ALL,SLURM_FLOX_ENV=youruser/ml-stack job.sh
```

### 5.2 Environment Modules Integration

If your site uses Lmod or Environment Modules, you can create a module file
that activates Flox:

Create `/etc/modulefiles/flox-env/ml-stack`:

```tcl
#%Module1.0
proc ModulesHelp { } {
    puts stderr "Activates the Flox ml-stack environment"
}
module-whatis "Flox ml-stack environment"

# Set the environment variable; job scripts still need flox activate
setenv SLURM_FLOX_ENV "youruser/ml-stack"
```

Users then do:

```bash
module load flox-env/ml-stack
sbatch job.sh   # job.sh reads $SLURM_FLOX_ENV
```

### 5.3 Wrapper Script for Users

Provide a convenience wrapper at `/usr/local/bin/sflox`:

```bash
#!/bin/bash
# sflox — submit a Slurm job inside a Flox environment
# Usage: sflox <flox-env> [sbatch-args...] -- <command>
set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: sflox <flox-env> [sbatch-args...] -- <command>"
    echo "Example: sflox youruser/ml-stack --gres=gpu:1 -- python3 train.py"
    exit 1
fi

FLOX_ENV="$1"; shift

# Split on --
SBATCH_ARGS=()
CMD_ARGS=()
found_sep=false
for arg in "$@"; do
    if [ "$arg" = "--" ]; then
        found_sep=true
        continue
    fi
    if $found_sep; then
        CMD_ARGS+=("$arg")
    else
        SBATCH_ARGS+=("$arg")
    fi
done

if [ ${#CMD_ARGS[@]} -eq 0 ]; then
    echo "Error: no command specified after --"
    exit 1
fi

# Create job script
JOBSCRIPT=$(mktemp /tmp/sflox-XXXXXX.sh)
cat > "$JOBSCRIPT" << EOF
#!/bin/bash
#SBATCH --job-name=flox-job
#SBATCH --output=flox-%j.out
flox activate -r "$FLOX_ENV" -- ${CMD_ARGS[@]}
EOF

sbatch "${SBATCH_ARGS[@]}" "$JOBSCRIPT"
rm -f "$JOBSCRIPT"
```

Usage:

```bash
sflox youruser/ml-stack --gres=gpu:1 --partition=gpu -- python3 train.py
```

---

## Phase 6: Verification Checklist

Run through these checks to confirm everything works end-to-end.

### Controller

- [ ] `flox --version` works
- [ ] Test environment activates: `flox activate -r youruser/my-env -- echo OK`
- [ ] If using NFS: `/nix` is exported (`showmount -e localhost`)

### Compute Nodes

For each compute node:

- [ ] `ssh root@nodeXX 'flox --version'` returns a version
- [ ] If NFS: `ssh root@nodeXX 'mount | grep /nix'` shows the NFS mount
- [ ] Environment activates: `ssh root@nodeXX 'flox activate -r youruser/my-env -- echo OK'`

### Job Submission

- [ ] Submit a trivial job:
  ```bash
  sbatch --wrap='flox activate -r youruser/my-env -- python3 -c "print(\"hello from flox\")"'
  ```
- [ ] Check output file confirms it ran inside the Flox environment
- [ ] Submit a GPU job (if applicable) and verify CUDA is available

---

## Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| `flox: command not found` on compute node | Flox not installed or not in PATH | Install Flox; check that `/usr/local/bin` or Flox install path is in the job's PATH |
| `error: getting status of /nix/store/...` | NFS not mounted or stale mount | Verify NFS mount on compute node; `mount /nix` or check `/etc/fstab` |
| First job very slow | Downloading packages on first activation | Pre-warm with prolog (§5.1) or `flox activate -r env -- true` on each node |
| `flox activate` hangs in job | Interactive prompt in hook | Ensure hooks are non-interactive; use `flox activate -- cmd` (non-interactive mode) |
| Permission denied on /nix | NFS export missing `no_root_squash` | Update `/etc/exports` with `no_root_squash`, re-export |
| Environment not found | Not pushed to FloxHub / typo in name | `flox push` from controller; verify with `flox search` |

---

## Decision Matrix: Which Option to Choose

| Factor | Option A (NFS /nix) | Option B (Independent) |
|--------|---------------------|----------------------|
| Shared storage available | Required | Not needed |
| Disk usage | Low (single copy) | High (copy per node) |
| First-job latency | None (already in store) | High (downloads packages) |
| Network dependency | NFS must be up | Only for FloxHub pull |
| Node independence | Nodes depend on NFS | Fully independent |
| Setup complexity | Moderate (NFS config) | Low (just install Flox) |
| Best for | Persistent clusters with shared FS | Cloud/ephemeral nodes, small clusters |
