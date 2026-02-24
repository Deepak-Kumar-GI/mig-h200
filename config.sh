#!/bin/bash
# ==============================================================
# Global Configuration - NVIDIA MIG/CDI Toolkit
# ==============================================================

# -------------------------
# Cluster / Node Settings
# -------------------------
WORKER_NODE="gu-k8s-worker"
GPU_OPERATOR_NAMESPACE="gpu-operator"

# -------------------------
# MIG Configuration
# -------------------------
MIG_CONFIG_FILE="custom-mig-config.yaml"

# -------------------------
# Global Lock File
# -------------------------
GLOBAL_LOCK_FILE="/var/lock/nvidia-mig-config.lock"

# -------------------------
# Logging
# -------------------------
BASE_LOG_DIR="logs"

# -------------------------
# MIG Wait Settings
# -------------------------
MAX_RETRIES=15
SLEEP_INTERVAL=20
MIN_SUCCESS_ATTEMPT=2
MAX_FAILED_ALLOWED=2

# -------------------------
# Retry / Sleep Settings
# -------------------------
MIG_MAX_APPLY_ATTEMPTS=3
TEMP_LABEL_SLEEP=20
CUSTOM_LABEL_SLEEP=20
