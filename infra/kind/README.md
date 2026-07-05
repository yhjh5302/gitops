# Kind Local Cluster Provisioning

This directory contains configuration files and helper scripts for provisioning a local development cluster using `kind` (Kubernetes in Docker).

---

## 1. Interactive Provisioning (Recommended)

You can provision and bootstrap the local cluster interactively:

```bash
# Grant execution permissions
chmod +x setup-cluster.sh

# Run the interactive setup
./setup-cluster.sh
```

Follow the menu choices to:
1. Create the Kind cluster
2. Deploy the Cilium CNI (with eBPF configuration)
3. Check the running status of your local nodes

---

## 2. Configuration and Scripts (Manual)

If you prefer to run steps manually, use the following resources:
- **`create-cluster.sh`**: Provisions a multi-node Kubernetes cluster locally using kind. It disables the default Kind CNI.
- **`kind-config.yaml`**: Kind configuration file configuring the control-plane and worker nodes, disabling default CNI, and defining API server endpoints.
