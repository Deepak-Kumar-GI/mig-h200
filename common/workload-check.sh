#!/bin/bash
# ============================================================================
# GPU Workload Detection Utility
# ============================================================================
# Safety gate that prevents MIG/CDI operations while GPU workloads are active.
# Sourced by pre.sh and restart.sh.
#
# Reconfiguring MIG partitions or switching the container runtime while pods
# are using GPUs can cause data corruption, job failures, or kernel errors.
# This check forces operators to manually drain workloads first.
#
# LIMITATION: This check scans for dgx-* pods cluster-wide (all namespaces,
# all nodes). In a multi-DGX cluster where only one DGX is being
# reconfigured, it will flag workloads running on OTHER DGX nodes that are
# unaffected — producing false positives and blocking the operation
# unnecessarily. This script currently assumes a single-DGX cluster.
# To support multi-DGX, the check should filter pods scheduled on the
# target node only (e.g., using --field-selector spec.nodeName=$node).
#
# Author: GRIL Team <support.ai@giindia.com>
# Organization: Global Infoventures
# Date: 2026-02-26
# ============================================================================

# Check for active GPU workloads across all namespaces.
# Aborts script execution if any dgx-* pods are found.
#
# The check matches pods with the "dgx-" prefix, which is the naming
# convention for user GPU workloads in this cluster. Pods are searched
# across all namespaces (-A) since users may run workloads in any namespace.
#
# Arguments:
#   $1 - node: Target worker node hostname (currently unused; reserved for
#              future per-node filtering)
#
# Returns:
#   0 if no GPU workloads are running; exits with 1 if workloads are found
check_gpu_workloads() {
    local node="$1"

    echo "Checking for running GPU workloads (dgx-*)..."

    local pods
    # List pods in all namespaces and filter for dgx-* workloads.
    # `|| true` prevents set -e from aborting when grep finds no matches
    # (grep returns exit code 1 on no match).
    pods=$(kubectl get pods -A | grep dgx- || true)

    # -n = true if string is non-empty (i.e., matching pods were found)
    if [[ -n "$pods" ]]; then
        echo
        echo "[ERROR] The following GPU workloads are still running:"
        echo "$pods"
        echo
        echo "Please delete these workloads and re-run the script."
        exit 1
    else
        echo "[INFO] No GPU workloads running. Safe to proceed."
    fi
}
