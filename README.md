# NVIDIA DGX MIG Manager

Automated toolkit for partitioning NVIDIA H200 GPUs via MIG on DGX Kubernetes clusters. Provides a whiptail-based TUI for profile selection and handles the full reprovisioning lifecycle — backup, runtime switching, MIG apply, CDI generation, and node management.

## Prerequisites

- Root access on the Kubernetes head node
- `whiptail`, `kubectl`, `ssh`, `tput` installed
- Passwordless SSH to the DGX worker node
- NVIDIA GPU Operator deployed in the cluster

## Quick Start (TUI)

The recommended way to reconfigure MIG partitions:

```bash
./mig-configure.sh
```

The TUI walks you through:

1. **Welcome screen** — shows target node, GPU model, and current MIG state
2. **Profile selection** — pick a MIG partition profile for each GPU (or apply one profile to all)
3. **Review & confirm** — displays the selected configuration before applying

Once confirmed, the tool automatically runs the full workflow: backup → cordon → apply MIG config → validate → CDI generation → uncordon.

## Manual Workflow

For advanced or custom configurations where you need direct control over the ConfigMap:

```bash
# Step 1: Backup configs, switch runtime to AUTO, cordon node
./pre.sh

# Step 2: Edit the MIG partition layout
nano custom-mig-config.yaml

# Step 3: Delete any active GPU workloads (dgx-* pods)

# Step 4: Apply MIG config, validate, generate CDI, uncordon
./post.sh
```

## After DGX Restart

If the DGX system reboots, wait **10–15 minutes** for the GPU Operator to initialize, then restore CDI mode:

```bash
./restart.sh
```

> **Note:** When `CDI_ENABLED=false` in `config.sh`, `restart.sh` is a no-op.

## Configuration

All tunable parameters live in `config.sh`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `WORKER_NODE` | `gu-k8s-worker` | Target Kubernetes worker node hostname |
| `GPU_OPERATOR_NAMESPACE` | `gpu-operator` | Namespace for GPU Operator resources |
| `CDI_ENABLED` | `true` | Enable/disable CDI runtime operations |
| `LOG_RETENTION_DAYS` | `30` | Days to keep log directories (0 = disable cleanup) |
| `MAX_RETRIES` | `15` | MIG state polling attempts before timeout |
| `SLEEP_INTERVAL` | `20` | Seconds between MIG state polls |
| `MIG_MAX_APPLY_ATTEMPTS` | `3` | Full apply-and-poll cycles before giving up |

MIG partition profiles are defined in `custom-mig-config-template.yaml`.

## Logs

Each run creates a timestamped directory under `logs/`:

```
logs/20260301-143022/
├── mig-configure.log        # Full operation log (or pre.log / post.log)
└── backup/
    ├── cluster-policy.yaml   # GPU Operator ClusterPolicy snapshot
    ├── mig-configmap.yaml    # Previous MIG ConfigMap
    └── node-mig-labels.txt   # Previous MIG node labels
```

Directories older than `LOG_RETENTION_DAYS` are automatically pruned at the start of each run.

## Author

GRIL Team — Global Infoventures
<support.ai@giindia.com>
