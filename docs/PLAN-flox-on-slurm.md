# Plan: Running Flox Environments on Slurm Compute Nodes

## Goal

Enable Slurm users to submit jobs that run inside Flox environments on compute
nodes, providing reproducible, declarative dependency management for HPC workloads.

## Assumptions

- Controller node is already running (this machine)
- Compute nodes are Debian-based, reachable via SSH from the controller
- No shared filesystem is assumed (the installer distributes files via SCP)
- Flox is already installed on the controller

## Important: How Flox Works

Flox is built on Nix. The `flox` binary itself lives inside `/nix/store/` (with
a symlink at `/usr/bin/flox`). Flox uses the `nix-daemon` for store operations,
communicating via a Unix socket at `/nix/var/nix/daemon-socket/socket`.

This means every node that runs `flox activate` needs:
1. A local, writable `/nix/var` (for the daemon socket and SQLite database)
2. A running `nix-daemon` (installed automatically by the Flox installer)
3. The required packages present in `/nix/store`

A naive read-only NFS mount of `/nix` does **not** work because:
- Unix domain sockets do not work over NFS
- `nix-daemon` needs write access to `/nix/var`
- `flox activate` connects to the local daemon socket on every invocation

## Architecture Overview

```
Controller (this node)
├── Flox installed (/usr/bin/flox → /nix/store/.../bin/flox)
├── /nix/store (local, writable)
├── Environments authored here or pulled from FloxHub
│
├── Option A: LAN binary cache (recommended for larger clusters)
│   ├── Controller runs nix-serve on the LAN
│   ├── Compute nodes have independent Flox installs
│   └── Packages download from controller over HTTP instead of the internet
│
└── Option B: Independent Flox per node (simplest setup)
    └── Each node pulls environments from FloxHub directly
```

Choose **one** of Option A or Option B based on your cluster size and network.

---

## Phase 1: Install Flox on All Nodes

Every node (controller and compute) needs its own Flox installation with a
local, writable `/nix`.

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
# Note: this skips node ranges like node[01-10] — expand those manually
NODES=$(grep -oP '^NodeName=\K[^\s]+' /etc/slurm/slurm.conf \
    | grep -v '\[' \
    | tr ',' '\n')

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

## Phase 2: Choose a Package Distribution Strategy

Both options require Flox installed on every node (Phase 1). The difference is
how packages get into each node's `/nix/store`.

### Option A: LAN Binary Cache (recommended for larger clusters)

Run a Nix binary cache on the controller so compute nodes download packages
over the LAN instead of the internet. This is faster and reduces external
bandwidth.

**On the controller — install and start nix-serve:**

```bash
# Install nix-serve (a lightweight HTTP binary cache server)
nix-env -iA nixpkgs.nix-serve

# Generate a signing key pair for the cache
nix-store --generate-binary-cache-key controller-cache cache-priv-key.pem cache-pub-key.pem
sudo mv cache-priv-key.pem /etc/nix/
sudo chmod 600 /etc/nix/cache-priv-key.pem

# Start nix-serve (serves /nix/store over HTTP on port 5000)
# For production, create a systemd unit instead of running in foreground
nix-serve --port 5000 --sign /etc/nix/cache-priv-key.pem &
```

Create a systemd unit for persistence (`/etc/systemd/system/nix-serve.service`):

```ini
[Unit]
Description=Nix binary cache server
After=network.target

[Service]
ExecStart=/root/.nix-profile/bin/nix-serve --port 5000 --sign /etc/nix/cache-priv-key.pem
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nix-serve
```

**On each compute node — configure the controller as a substituter:**

```bash
# Get the public key from the controller
PUBLIC_KEY=$(cat cache-pub-key.pem)

# Add to each compute node's nix.conf
ssh root@compute01 "cat >> /etc/nix/nix.conf << EOF
extra-substituters = http://controller:5000
extra-trusted-public-keys = $PUBLIC_KEY
EOF
systemctl restart nix-daemon"
```

Replace `controller` with the actual hostname or IP of the controller node.

**How it works:** When a compute node runs `flox activate`, `nix-daemon` checks
the controller's binary cache first. If the package is there (because you
already built/pulled the environment on the controller), it downloads over the
LAN. Cache misses fall through to the default substituters (cache.nixos.org,
cache.flox.dev).

**Pre-populate the cache** by activating environments on the controller first:

```bash
flox activate -r youruser/my-env -- true
```

### Option B: Independent Flox per Node (simplest setup)

Each compute node maintains its own `/nix/store`. Environments are pulled from
FloxHub on first activation and cached locally.

**Pros:** No additional infrastructure. Nodes are fully independent.
**Cons:** First activation on each node downloads all packages from the internet.
More total disk usage across the cluster.

No additional setup beyond Phase 1 — Flox installs its own `/nix/store` on
each node.

To pre-warm a node's cache (optional):

```bash
ssh root@compute01 'flox activate -r youruser/my-env -- true'
```

---

## Phase 3: Create and Publish a Flox Environment

You need an environment that compute nodes can activate. Two approaches:

### 3a. FloxHub Remote Environments (recommended)

Create and push an environment from the controller:

```bash
mkdir -p ~/flox-envs/my-hpc-stack && cd ~/flox-envs/my-hpc-stack
flox init
flox install python311Full uv gcc cmake   # whatever your workload needs
flox activate -- python3 --version        # verify it works

# Push to FloxHub (requires flox auth login first)
flox auth login
git init && git add -A && git commit -m "Initial environment"
git remote add origin <your-git-remote-url>
git push -u origin main
flox push
```

Users reference it in jobs as `flox activate -r youruser/my-hpc-stack -- ...`

### 3b. Project-Local Environments (requires shared filesystem)

If your project directory lives on shared storage (NFS home directories, Lustre,
etc.), the `.flox/` directory is accessible to all nodes:

```bash
cd /shared/projects/my-project
flox init
flox install python311Full numpy
```

Jobs `cd` to the project and activate directly. Each node still needs the
packages in its local `/nix/store` — the `.flox/` directory is just metadata.
With Option A (LAN cache), packages download quickly from the controller.
With Option B, they download from the internet on first use.

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

For complex jobs, write a separate script and invoke it through Flox:

```bash
#!/bin/bash
#SBATCH --job-name=training
#SBATCH --output=train-%j.out
#SBATCH --gres=gpu:1

flox activate -r youruser/ml-stack -- bash -c '
set -euo pipefail
echo "Python: $(python3 --version)"
cd "$SLURM_SUBMIT_DIR"
python3 train.py --epochs 100
'
```

Or keep the work in a separate script (cleaner for large jobs):

```bash
#!/bin/bash
#SBATCH --job-name=training
#SBATCH --output=train-%j.out
#SBATCH --gres=gpu:1

flox activate -r youruser/ml-stack -- ./train_wrapper.sh
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

### 5.1 Slurm Prolog — Pre-Cache Environments on Compute Nodes

Add a compute-node prolog script so environments are warm before jobs start.
This avoids first-run download latency inside job wall time.

Create `/etc/slurm/prolog.d/flox-cache.sh` on each compute node:

```bash
#!/bin/bash
# Pre-cache Flox environment if SLURM_FLOX_ENV is set.
# Note: Prolog runs as root. We pre-warm the store paths so they're
# available when the job user activates the same environment.
if [ -n "${SLURM_FLOX_ENV:-}" ]; then
    flox activate -r "$SLURM_FLOX_ENV" -- true 2>/dev/null || true
fi
```

Add to slurm.conf on the controller:

```
Prolog=/etc/slurm/prolog.d/flox-cache.sh
```

Distribute slurm.conf and the prolog script to all compute nodes, then
`scontrol reconfigure`.

Users submit with:

```bash
sbatch --export=ALL,SLURM_FLOX_ENV=youruser/ml-stack job.sh
```

> **Note:** The prolog runs as root, which warms the `/nix/store` paths (shared
> across all users on the node). The job user's `flox activate` will then find
> all packages already present and start instantly.

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
# Usage: sflox <flox-env> [sbatch-args...] -- <command> [args...]
set -euo pipefail

if [ $# -lt 3 ]; then
    echo "Usage: sflox <flox-env> [sbatch-args...] -- <command> [args...]"
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

# Build a properly quoted command string for the job script
QUOTED_CMD=""
for arg in "${CMD_ARGS[@]}"; do
    QUOTED_CMD+="$(printf '%q ' "$arg")"
done

# Create job script
JOBSCRIPT=$(mktemp /tmp/sflox-XXXXXX.sh)
cat > "$JOBSCRIPT" << EOF
#!/bin/bash
#SBATCH --job-name=flox-job
#SBATCH --output=flox-%j.out
flox activate -r "$FLOX_ENV" -- $QUOTED_CMD
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
- [ ] If using Option A: `curl http://localhost:5000/nix-cache-info` returns cache info

### Compute Nodes

For each compute node:

- [ ] `ssh root@nodeXX 'flox --version'` returns a version
- [ ] `ssh root@nodeXX 'systemctl is-active nix-daemon'` returns `active`
- [ ] If using Option A: `ssh root@nodeXX 'grep controller /etc/nix/nix.conf'` shows substituter
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
| `flox: command not found` on compute node | Flox not installed or not in PATH | Install Flox; verify `/usr/bin/flox` symlink exists |
| `error: getting status of /nix/store/...` | Store path not present on this node | Pre-warm with `flox activate -r env -- true`; if using Option A, verify binary cache is reachable |
| First job very slow | Downloading packages on first activation | Pre-warm with prolog (§5.1) or `flox activate -r env -- true` on each node |
| `flox activate` hangs in job | Interactive prompt in hook | Ensure hooks are non-interactive; use `flox activate -- cmd` (non-interactive mode) |
| `nix-daemon` not running | Service stopped or failed | `systemctl restart nix-daemon` on the affected node |
| Binary cache not reachable | Firewall or hostname resolution | Verify `curl http://controller:5000/nix-cache-info` from compute node |
| Environment not found | Not pushed to FloxHub / typo in name | `flox push` from controller; verify with `flox search` |

---

## Decision Matrix: Which Option to Choose

| Factor | Option A (LAN binary cache) | Option B (Independent) |
|--------|----------------------------|----------------------|
| Additional infra | nix-serve on controller | None |
| Disk usage | Medium (shared cache avoids re-downloads) | Higher (each node downloads independently) |
| First-job latency | Low (LAN download) | High (internet download) |
| Network dependency | LAN to controller | Internet to FloxHub/cache.nixos.org |
| Node independence | Needs controller reachable for cache misses | Fully independent |
| Setup complexity | Moderate (nix-serve + key signing) | Low (just install Flox) |
| Best for | Larger persistent clusters | Small clusters, cloud/ephemeral nodes |
