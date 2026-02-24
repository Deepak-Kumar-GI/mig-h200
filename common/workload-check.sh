#!/bin/bash
# ==============================================================
# GPU Workload Detection Utility
# ==============================================================

check_gpu_workloads() {
    local node="$1"

    echo "Checking for running GPU workloads (dgx-*)..."

    local pods
    pods=$(kubectl get pods -A | grep dgx- || true)

    if [[ -n "$pods" ]]; then
        echo
        echo "[ERROR] The following GPU workloads are still running:"
        echo "$pods"
        echo
        echo "Please delete these workloads and re-run pre.sh"
        exit 1
    else
        echo "[INFO] No GPU workloads running. Safe to proceed."
    fi
}