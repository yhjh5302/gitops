# Infrastructure Addons Setup

This directory contains the scripts and templates to configure core cluster infrastructure addons (Cilium CNI, Cert Manager, HashiCorp Vault, and External Secrets Operator).

---

## 1. Directory Structure

| File | Role | Description |
| :--- | :--- | :--- |
| **`setup-addons.sh`** | **Addon Setup Orchestrator** | Coordinates setup, verifies status, skips healthy addons, and automatically reinstalls failed ones. |
| `install-cilium.sh` | Cilium CNI Installation | Installs the Cilium CNI using eBPF host routing and kube-proxy replacement mode. |
| `install-cert-manager.sh` | Cert Manager Installation | Installs cert-manager with CRDs enabled to manage TLS certificates. |
| `install-vault.sh` | HashiCorp Vault Setup | Deploys Vault in Dev Mode and seeds Git credentials/webhook secrets into Vault. |
| `install-external-secrets.sh` | External Secrets Operator | Deploys ESO and configures the `ClusterSecretStore` backended by Vault. |
| `vault-config.env.example` | Configuration Template | Configuration guide using Bash Here-Doc format to write the PEM key cleanly. |

---

## 2. Usage Instructions (Unified Installation)

After provisioning your Kubernetes cluster (Kind or Bare-metal/VM), follow these steps to configure the cluster infrastructure addons:

### Step 1: Copy and Configure Environment Variables
Copy the template configuration file:
```bash
cp infra/common/vault-config.env.example infra/common/vault-config.env
```
* Open `infra/common/vault-config.env` and populate `REPO_URL`, `GITHUB_APP_ID`, `GITHUB_APP_INSTALLATION_ID`, and `WEBHOOK_SECRET`.
* Copy and paste your GitHub App RSA Private Key `.pem` contents directly between the `<< 'EOF'` and `EOF` lines of the `GITHUB_APP_PRIVATE_KEY` block.

### Step 2: Run the Unified Setup Script
Trigger the addon orchestrator script:
```bash
bash infra/common/setup-addons.sh
```

> [!NOTE]
> * **Auto-Discovery**: The orchestrator automatically retrieves the Kubernetes API server host/port and Node Pod CIDR from your current context to configure Cilium CNI dynamically.
> * **Status Verification (Skip/Reinstall)**: If an addon is already deployed successfully, the script skips it. If it exists in a failed/corrupted state, it will automatically uninstall and perform a clean reinstallation.

---

## 3. Manual Addon Installation (Advanced)

Each script can also be executed individually if you want to deploy a single component manually with custom parameters.

Example (Manual Cilium Installation):
```bash
# Usage: bash install-cilium.sh [K8S_HOST] [K8S_PORT] [POD_CIDR]
bash infra/common/install-cilium.sh 192.168.1.100 6443 10.244.0.0/16
```
