#!/usr/bin/env bash
# Kubernetes Kubeadm Cluster Setup Configurations

# Kubernetes Version Series (e.g. v1.35.6)
export KUBERNETES_VERSION="v1.35.6"

# Kubeadm Init Options
export POD_NETWORK_CIDR="10.233.0.0/16"
export SERVICE_CIDR="10.234.0.0/16"
export CONTROL_PLANE_ENDPOINT="cluster-endpoint:6443"
export IMAGE_REPOSITORY="registry.k8s.io"

# Containerd Configurations
export DOCKER_DATA_ROOT="/var/lib/docker"
export DOCKER_EXEC_ROOT="/var/run/docker"
export CONTAINERD_ROOT="/var/lib/containerd"
export CONTAINERD_STATE="/run/containerd"
export SANDBOX_IMAGE="registry.k8s.io/pause:3.10.2"

# NVIDIA GPU configurations
export NVIDIA_DRIVER_VERSION="580"

# Kubeadm Log Verbosity Level (e.g. 5 for debug logs, leave empty for default)
export KUBEADM_VERBOSITY="6"
