# Partitioning NVIDIA H200 GPUs with the GPU MIG Manager

---

## Main Procedure

### Step 1: Log in as root on the head node

```bash
ssh <head-node>
```

### Step 2: Go to the GU headnode directory

```bash
cd /root/mig-partion/script
```

### Step 3: Execute the pre script

```bash
./pre.sh
```

### Step 4: Check running user workloads (users generally run pods)

```bash
kubectl get pods -A
```

### Step 5: Delete user pods/workloads if they exist

### Step 6: Open the MIG configuration file

```bash
nano custom-mig-config.yaml
```

### Step 7: Execute the post script

```bash
./post.sh
```

---

## Restart Procedure

> **Note:** If the DGX system restarts, run `restart.sh` 10–15 minutes after the DGX starts successfully.

### Step 1: Log in as root on the head node

```bash
ssh <head-node>
```

### Step 2: Go to the directory

```bash
cd /root/mig-partion/script
```

### Step 3: Run the restart script

```bash
./restart.sh
```

---

## Script Details

### `pre.sh`

* Collect backup
* Change mode from CDI to Auto
* Cordon the worker node

### `post.sh`

* Apply configure
* Check that the node label is successful
* Verify the new MIG configuration
* Generate CDI
* Change mode from Auto to MIG
* Uncordon the worker node

### `restart.sh`

* Change mode from Auto to CDI
