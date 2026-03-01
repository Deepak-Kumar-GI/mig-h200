#!/bin/bash
# ============================================================================
# Global Configuration - NVIDIA MIG/CDI Toolkit
# ============================================================================
# Central configuration file sourced by all scripts (pre.sh, post.sh,
# restart.sh). Defines cluster targets, retry behaviour, and timing
# constants used throughout the MIG reprovisioning workflow.
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-26
# ============================================================================

# ============================================================================
# CLUSTER / NODE SETTINGS
# ============================================================================

# Kubernetes worker node hostname that hosts the NVIDIA H200 GPUs.
# Used for kubectl commands, SSH access, and node label operations.
WORKER_NODE="gu-k8s-worker"

# Namespace where the NVIDIA GPU Operator is deployed.
# Used to locate MIG Manager pods and MIG ConfigMaps.
GPU_OPERATOR_NAMESPACE="gpu-operator"

# ============================================================================
# MIG CONFIGURATION
# ============================================================================

# Path to the Kubernetes ConfigMap YAML that defines the desired
# MIG partition layout. Applied by post.sh during reprovisioning.
MIG_CONFIG_FILE="custom-mig-config.yaml"

# Path to the MIG configuration template file that defines available
# profiles for the TUI. Change this for different GPU models.
MIG_TEMPLATE_FILE="custom-mig-config-template.yaml"

# ============================================================================
# CDI / RUNTIME
# ============================================================================

# Whether to enable CDI (Container Device Interface) operations.
# When true: the toolkit backs up runtime config, switches to AUTO mode
# (pre-phase), generates CDI specs, and switches to CDI mode (post-phase).
# When false: all CDI/runtime-mode operations are skipped entirely.
# restart.sh becomes a no-op.
#
# Set to false if your environment does not use CDI for GPU device exposure.
CDI_ENABLED=true

# ============================================================================
# GLOBAL LOCK
# ============================================================================

# Lock file path used by flock to prevent concurrent MIG/CDI operations.
# Placed in /var/lock so it is automatically cleaned up on reboot.
GLOBAL_LOCK_FILE="/var/lock/nvidia-mig-config.lock"

# ============================================================================
# LOGGING
# ============================================================================

# Base directory for timestamped run logs and configuration backups.
# Each run creates a subdirectory: logs/YYYYMMDD-HHMMSS/
BASE_LOG_DIR="logs"

# ============================================================================
# MIG STATE POLLING
# ============================================================================

# Maximum polling attempts before timing out while waiting for
# MIG state to reach "success". Total wait = MAX_RETRIES * SLEEP_INTERVAL
# (15 * 20s = 5 minutes).
MAX_RETRIES=15

# Seconds to sleep between MIG state polling attempts.
SLEEP_INTERVAL=20

# Minimum poll iteration at which a "success" state is accepted.
# Rejecting success before this count protects against stale labels
# that report success before the MIG Manager has actually reconfigured.
MIN_SUCCESS_ATTEMPT=2

# Number of "failed" states tolerated before aborting.
# Allows transient failures during GPU reconfiguration.
MAX_FAILED_ALLOWED=2

# ============================================================================
# MIG APPLY RETRY / LABEL TIMING
# ============================================================================

# Number of full apply-and-poll cycles before giving up.
# Each attempt applies the ConfigMap and cycles node labels to
# trigger the MIG Manager.
MIG_MAX_APPLY_ATTEMPTS=3

# Seconds to wait after setting the temporary label ("temp") before
# applying the real label. Gives the MIG Manager time to detect
# the label change and begin reconfiguration.
TEMP_LABEL_SLEEP=20

# Seconds to wait after setting the custom-mig-config label before
# polling state. Allows Kubernetes label propagation and MIG Manager
# to start processing.
CUSTOM_LABEL_SLEEP=20
