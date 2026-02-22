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

### Step 7: Apply the configuration file

```bash
kubectl apply -f custom-mig-config.yaml
```

### Step 8: Apply the temporary label

```bash
kubectl label node gu-k8s-worker nvidia.com/mig.config=temp --overwrite
```

### Step 9: Apply the MIG configuration label

```bash
kubectl label node gu-k8s-worker nvidia.com/mig.config=custom-mig-config --overwrite
```

### Step 10: Execute the post script

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

* Check that the node label is successful
* Verify the new MIG configuration
* Generate CDI
* Change mode from Auto to MIG
* Uncordon the worker node

### `restart.sh`

* Generate CDI
* Change mode from Auto to CDI



