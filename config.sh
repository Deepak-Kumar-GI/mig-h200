#!/bin/bash
# ==============================================================
# Global Configuration - NVIDIA MIG/CDI Toolkit
# ==============================================================
# This file contains all shared configuration variables used by:
#   - pre.sh
#   - post.sh
#   - restart.sh
# ==============================================================

# -------------------------
# Cluster / Node Settings
# -------------------------
# Target worker node where MIG/CDI operations occur
WORKER_NODE="gu-k8s-worker"

# NVIDIA GPU Operator namespace
GPU_OPERATOR_NAMESPACE="gpu-operator"

# -------------------------
# Global Lock File
# -------------------------
# Ensures only ONE operation (pre/post/restart) runs at a time
GLOBAL_LOCK_FILE="/var/lock/nvidia-mig-config.lock"

# -------------------------
# Logging Configuration
# -------------------------
# Base directory for run logs
BASE_LOG_DIR="logs"

# -------------------------
# MIG Wait Settings (Used in post.sh)
# -------------------------
# Maximum polling attempts for MIG success
MAX_RETRIES=15

# Time (seconds) between polling attempts
SLEEP_INTERVAL=20

# Minimum successful attempts before accepting success
MIN_SUCCESS_ATTEMPT=2

# Maximum allowed failure states before aborting
MAX_FAILED_ALLOWED=2
