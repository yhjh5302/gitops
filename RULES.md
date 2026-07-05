# GitOps Development Rules

This document outlines the coding style, design patterns, and repository conventions for managing Kubernetes manifests within this GitOps structure.

---

## 1. Comment and Documentation Conventions

- **Language**: Write all documentation, README files, and manifest comments in **English**.
- **Style**: Comments must be concise, technically dry, and strictly objective. Do not include unnecessary explanations or placeholders.
- **Scope**: Use comments in YAML manifests only to explain non-standard configurations (e.g., sync wave dependencies, specific annotations, or fallback ports).

---

## 2. Kubernetes and Ingress Design

- **Terminology**: Use standard, native Kubernetes API resources and terminology.
- **Virtualization & Network Isolation**: 
  - Maintain container network isolation boundaries.
  - Avoid host-level networking configurations (`hostNetwork: true` or `hostPort` bindings) in application workload pods unless explicitly required for low-level infrastructure operations.
- **Ingress and Gateway API**: Route inbound external traffic through the central Gateway API or Ingress controller rather than exposing pods directly. Use native routing configurations (e.g., `HTTPRoute`, `UDPRoute`).

---

## 3. GitOps and Manifest Management

- **Repository Referencing**: Configure `repoURL` references to dynamically or statically align with the designated target repository. Avoid environment-specific hardcoded values where template variables can be utilized.
- **CRD Lifecycle Isolation**:
  - Exclude Custom Resource Definitions (CRDs) from automatic pruning and dynamic synchronization to prevent accidental system-wide resource loss.
  - Set `spec.source.helm.skipCrds: true` in all system Application manifests to isolate CRD management from application updates.
- **Helm Chart Integrity**:
  - Do not modify Helm charts (`charts/` directories) directly. They must remain clean, vendor-pulled copies.
  - All configuration changes and customizations must be applied via values files or overrides in the Application manifests, not by editing chart templates.
- **Secret Management**:
  - Never commit unencrypted sensitive credentials, private keys, certificates, or API tokens to the repository.
  - Rely on secret rotation engines and operators (e.g., External Secrets Operator) to dynamically load secrets from secure external vaults.
