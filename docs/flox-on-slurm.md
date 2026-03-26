# Plan: Running Flox Environments on Slurm Compute Nodes

## Goal

Enable Slurm users to submit jobs that run inside Flox environments on compute
nodes, providing reproducible, declarative dependency management for HPC workloads.

## Assumptions

- Controller node is already running (this machine)
- Compute nodes are Debian-based, reachable via SSH from the controller
- No shared filesystem is assumed (the installer distributes files via SCP)
- Flox is already installed on the controller

## How It Works

Each compute node gets its own Flox installation. When a job runs
`flox activate -r youruser/my-env -- <command>`, Flox pulls the environment
from FloxHub, downloads any missing packages into the node's local `/nix/store`,
and runs the command with everything on PATH. After the first activation,
packages are cached locally and subsequent jobs start instantly.

That's it. No shared filesystem, no binary cache, no NFS — just install Flox
on your nodes, push an environment to FloxHub, and reference it in job scripts.

## What `flox activate -r` Actually Does

When you run `flox activate -r owner/env -- <command>`, this is the sequence:

1. **Check local cache** — looks for environment metadata in
   `~/.cache/flox/remote/<owner>/<env>/.flox/` (manifest, lockfile).
2. **Contact FloxHub** (HTTPS) — checks for updates to the environment. Also
   contacts GitHub to fetch the environment source if needed. This happens on
   every activation, even for cached environments.
3. **Resolve packages** — the lockfile (`manifest.lock`) contains specific
   `/nix/store/` paths for every package. If those paths are already in the
   local store, no download is needed. Missing packages are fetched from Nix
   substituters (cache.flox.dev, cache.nixos.org) via the local `nix-daemon`.
4. **Build composite environment** — Nix builds an "environment" store path
   (`/nix/store/...-environment-develop`) that contains symlinks to all
   individual package paths. This is what `$FLOX_ENV` points to.
5. **Create run symlink** — a symlink is created at
   `~/.cache/flox/run/<owner>/<system>.<env>.<mode>` pointing to the composite
   store path.
6. **Set environment variables** — `PATH` gets the composite `bin/` directory,
   `$FLOX_ENV`, `$FLOX_ENV_CACHE`, `$FLOX_ENV_PROJECT` are set.
7. **Run hooks** — the `[hook]` on-activate script runs (if defined).
8. **Execute command** — spawns `<command>` in a subshell with the activated
   environment.

### Key environment variables during activation

| Variable | Value | Persists across activations? |
|----------|-------|----------------------------|
| `$FLOX_ENV` | `/nix/store/...-environment-develop` (composite of all packages) | Rebuilt each time |
| `$FLOX_ENV_CACHE` | `~/.cache/flox/remote/<owner>/<env>/.flox/cache` | Yes (local to node) |
| `$FLOX_ENV_PROJECT` | Current working directory (where `flox activate` was run) | N/A |

### Trust and non-interactive activation

Activating someone else's environment runs their hooks, which could execute
arbitrary code. Flox handles this with trust:

- **Your own environments** (`youruser/env`) are always trusted automatically.
- **Other users' environments** prompt for confirmation — this will **hang in
  a Slurm batch job**. To avoid this:
  - Use `-t` flag: `flox activate -r otheruser/env -t -- cmd`
  - Pre-configure trust: `flox config --set trusted_environments.\"otheruser/env\" trust`

### Network requirements

`flox activate -r` contacts FloxHub on every invocation (even for cached
environments) to check for updates. This means compute nodes need outbound
HTTPS access to:
- FloxHub API (hub.flox.dev)
- GitHub (github.com — for environment source)
- Nix caches (cache.flox.dev, cache.nixos.org — for package downloads)

If your compute nodes are air-gapped or have restricted internet access,
use the LAN binary cache approach (§5.3) and local `.flox/` directories
instead of `flox activate -r`.

### Activation modes

Flox supports two activation modes (controlled by `-m` flag or manifest setting):
- **dev** (default) — includes all packages, suitable for development/interactive use
- **run** — minimal runtime-only packages (if `runtime-packages` is configured)

For Slurm jobs, the default `dev` mode is usually what you want unless you've
specifically configured `runtime-packages` in your builds.

## Technical Notes

Flox is built on Nix. The `flox` binary itself lives inside `/nix/store/` (with
a symlink at `/usr/bin/flox`). Flox uses the `nix-daemon` for store operations,
communicating via a Unix socket at `/nix/var/nix/daemon-socket/socket`. This
means every node needs its own Flox installation with a local, writable `/nix`.
A read-only NFS mount of `/nix` does **not** work (Unix domain sockets don't
traverse NFS, and `nix-daemon` needs write access to `/nix/var`).

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

## Phase 2: Create and Publish a Flox Environment

### 2a. FloxHub Remote Environments (recommended)

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

### 2b. Project-Local Environments (requires shared filesystem)

If your project directory lives on shared storage (NFS home directories, Lustre,
etc.), the `.flox/` directory is accessible to all nodes:

```bash
cd /shared/projects/my-project
flox init
flox install python311Full numpy
```

Jobs `cd` to the project and activate directly. Each node still needs the
packages in its local `/nix/store` — the `.flox/` directory is just metadata.
Packages download from FloxHub/Nix caches on first use and are cached locally.

---

## Phase 3: Submit Slurm Jobs Using Flox

### 3.1 Basic Job Script

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

### 3.2 Multi-Line Job with Flox

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

### 3.3 Project-Local Environment (shared storage)

```bash
#!/bin/bash
#SBATCH --job-name=analysis
#SBATCH --output=analysis-%j.out

cd /shared/projects/my-project
flox activate -- python3 analyze.py
```

### 3.4 GPU Job with CUDA Flox Environment

```bash
#!/bin/bash
#SBATCH --job-name=gpu-train
#SBATCH --gres=gpu:1
#SBATCH --partition=gpu

flox activate -r youruser/cuda-ml-stack -- python3 train_gpu.py
```

---

## Phase 4: Verification Checklist

Run through these checks to confirm everything works end-to-end.

### Controller

- [ ] `flox --version` works
- [ ] Test environment activates: `flox activate -r youruser/my-env -- echo OK`

### Compute Nodes

For each compute node:

- [ ] `ssh root@nodeXX 'flox --version'` returns a version
- [ ] `ssh root@nodeXX 'systemctl is-active nix-daemon'` returns `active`
- [ ] Environment activates: `ssh root@nodeXX 'flox activate -r youruser/my-env -- echo OK'`

### Job Submission

- [ ] Submit a trivial job:
  ```bash
  sbatch --wrap='flox activate -r youruser/my-env -- python3 -c "print(\"hello from flox\")"'
  ```
- [ ] Check output file confirms it ran inside the Flox environment
- [ ] Submit a GPU job (if applicable) and verify CUDA is available

---

## Phase 5: Optional Enhancements

### 5.1 Pre-Warm Compute Nodes

The first `flox activate -r` on a node downloads packages from the internet,
which can be slow. Pre-warm nodes after installing Flox:

```bash
for node in $NODES; do
    echo "Pre-warming $node..."
    ssh root@"$node" 'flox activate -r youruser/my-env -- true' &
done
wait
echo "All nodes warmed."
```

### 5.2 Slurm Prolog — Automatic Pre-Caching

Add a compute-node prolog script so environments are warm before jobs start.

Create `/etc/slurm/prolog.d/flox-cache.sh` on each compute node:

```bash
#!/bin/bash
# Pre-cache Flox environment if SLURM_FLOX_ENV is set.
# Prolog runs as root. This warms the /nix/store paths (shared across
# all users on the node), so the job user's flox activate starts instantly.
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

### 5.3 LAN Binary Cache (for Nix-savvy shops)

If you run a larger cluster and want to avoid each node downloading packages
from the internet independently, you can run a Nix binary cache on the
controller. Compute nodes then fetch packages over the LAN — much faster, and
only one node (the controller) ever hits the internet.

This is the standard Nix multi-node pattern using `nix-serve`. It requires
generating signing keys, running a systemd service, and configuring each
compute node's `/etc/nix/nix.conf` with the controller as a substituter.

**On the controller:**

```bash
# Install nix-serve (lightweight HTTP binary cache server)
nix-env -iA nixpkgs.nix-serve

# Generate a signing key pair
nix-store --generate-binary-cache-key controller-cache cache-priv-key.pem cache-pub-key.pem
sudo mv cache-priv-key.pem /etc/nix/
sudo chmod 600 /etc/nix/cache-priv-key.pem
```

Create `/etc/systemd/system/nix-serve.service`:

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

**On each compute node:**

```bash
PUBLIC_KEY=$(cat cache-pub-key.pem)  # from the controller

ssh root@compute01 "cat >> /etc/nix/nix.conf << EOF
extra-substituters = http://controller:5000
extra-trusted-public-keys = $PUBLIC_KEY
EOF
systemctl restart nix-daemon"
```

Replace `controller` with the controller's hostname or IP.

After this, any `flox activate` on a compute node checks the controller's
cache first. Pre-populate it by activating environments on the controller:

```bash
flox activate -r youruser/my-env -- true
```

### 5.4 Environment Modules Integration

If your site uses Lmod or Environment Modules, you can create a module file
that sets the Flox environment for job scripts:

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

### 5.5 Wrapper Script for Users

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

## Troubleshooting

| Problem | Likely Cause | Fix |
|---------|-------------|-----|
| `flox: command not found` on compute node | Flox not installed or not in PATH | Install Flox; verify `/usr/bin/flox` symlink exists |
| `error: getting status of /nix/store/...` | Store path not present on this node | Pre-warm with `flox activate -r env -- true` on the node |
| First job very slow | Downloading packages on first activation | Pre-warm nodes (§5.1) or set up LAN binary cache (§5.3) |
| `flox activate` hangs in job | Interactive prompt in hook | Ensure hooks are non-interactive; use `flox activate -- cmd` (non-interactive mode) |
| `nix-daemon` not running | Service stopped or failed | `systemctl restart nix-daemon` on the affected node |
| Environment not found | Not pushed to FloxHub / typo in name | `flox push` from controller; verify with `flox search` |
