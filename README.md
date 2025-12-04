# Homelab RKE2 Cluster - Fleet GitOps Configuration

This repository contains the Infrastructure as Code (IaC) configuration for a homelab RKE2 Kubernetes cluster, managed using Rancher Fleet for GitOps-style deployments.

## Repository Structure

```
.
├── fleet.yaml                  # Root Fleet configuration
├── infra/                      # Infrastructure components
│   ├── cert-manager/          # TLS certificate management (Helm)
│   ├── cert-manager-config/   # Certificate issuers and certs (Kustomize)
│   ├── nginx-ingress/         # Ingress controllers
│   │   ├── internal/          # Internal ingress controller
│   │   └── external/          # External ingress controller with LoadBalancer
│   ├── longhorn/              # Longhorn storage configuration
│   ├── media-storage/         # Media-specific storage resources
│   └── authentik/             # Identity provider and SSO
└── apps/                       # Applications
    └── media-stack/           # Media server stack (Kustomize)
        ├── base/              # Shared resources (services, ingress)
        └── components/        # Individual applications
            ├── jellyfin/      # Media server
            ├── jellyseerr/    # Request management
            ├── sonarr/        # TV show PVR
            ├── radarr/        # Movie PVR
            ├── sabnzbd/       # Usenet download client
            ├── prowlarr/      # Indexer manager
            ├── profilarr/     # Profile management
            └── mover/         # Storage automation
```

## Fleet Configuration

### Overview

This repository uses Rancher Fleet for GitOps continuous deployment. Each component has a `fleet.yaml` file that defines:

- **defaultNamespace**: Target namespace for resources
- **helm**: Helm chart configuration (for Helm-based deployments)
- **kustomize**: Kustomize configuration (for manifest-based deployments)
- **labels**: Organizational labels for filtering and grouping
- **dependsOn**: Deployment dependencies to ensure proper ordering

### Deployment Order

Fleet automatically handles deployment ordering based on dependencies:

1. **Infrastructure Layer**
   - cert-manager (TLS certificate management)
   - cert-manager-config (issuers and certificates)
   - nginx-ingress (internal and external controllers)
   - longhorn (storage configuration)
   - media-storage (media-specific PVCs)
   - authentik (identity provider)

2. **Application Layer**
   - media-stack (complete media server suite)

## Components

### Infrastructure

#### cert-manager
- **Type**: Helm Chart
- **Purpose**: Automated TLS certificate provisioning and renewal
- **Version**: v1.15.3
- **Features**: DNS-01 challenge support with Cloudflare

#### cert-manager-config
- **Type**: Kustomize
- **Purpose**: ClusterIssuers and Certificate resources
- **Includes**:
  - Let's Encrypt production issuer
  - Wildcard certificates for media services
  - Harvester UI certificates
  - Cloudflare API credentials (sealed)

#### nginx-ingress
- **Type**: Helm Chart (2 instances)
- **Purpose**: HTTP/HTTPS traffic routing
- **Variants**:
  - **Internal**: Handles internal cluster traffic
  - **External**: Exposed via LoadBalancer (10.10.30.50)

#### longhorn
- **Type**: Kustomize
- **Purpose**: Custom StorageClass definitions
- **Note**: Longhorn itself is managed separately (typically via RKE2 or Rancher)

#### media-storage
- **Type**: Kustomize
- **Purpose**: PersistentVolumeClaims for media applications
- **Includes**:
  - Hot storage for active media
  - NFS-backed media library

#### authentik
- **Type**: Helm Chart
- **Purpose**: Identity provider and SSO platform
- **Version**: 2025.10.2
- **Dependencies**: Requires cert-manager-config

### Applications

#### media-stack
- **Type**: Kustomize
- **Purpose**: Complete media server automation suite
- **Components**:
  - **Jellyfin**: Media streaming server
  - **Jellyseerr**: Media request management
  - **Sonarr**: TV show automation
  - **Radarr**: Movie automation
  - **Sabnzbd**: Usenet download client
  - **Prowlarr**: Indexer aggregator
  - **Profilarr**: Profile synchronization
  - **Mover**: Storage tier management

## Usage

### Prerequisites

1. RKE2 Kubernetes cluster
2. Rancher Fleet installed
3. kubectl configured with cluster access
4. Cloudflare API credentials (for DNS-01 challenges)

### Deployment

#### Option 1: Fleet GitRepository (Recommended)

1. Create a Fleet GitRepo resource:

```yaml
apiVersion: fleet.cattle.io/v1alpha1
kind: GitRepo
metadata:
  name: homelab-rke2
  namespace: fleet-default
spec:
  repo: https://github.com/yourusername/homelab-rke2
  branch: main
  paths:
  - .
  targets:
  - clusterSelector:
      matchLabels:
        env: homelab
```

2. Apply the GitRepo:
```bash
kubectl apply -f gitrepo.yaml
```

Fleet will automatically discover and deploy all components based on the `fleet.yaml` files.

#### Option 2: Manual Application

Deploy individual components using kubectl:

```bash
# Deploy infrastructure
kubectl apply -k infra/cert-manager/
kubectl apply -k infra/cert-manager-config/
kubectl apply -k infra/nginx-ingress/internal/
kubectl apply -k infra/nginx-ingress/external/

# Deploy applications
kubectl apply -k apps/media-stack/
```

### Secrets Management

Sensitive data (like Cloudflare API keys) should be encrypted. Consider using:

- **Sealed Secrets**: Bitnami Sealed Secrets for encryption at rest
- **SOPS**: Mozilla SOPS with age or GPG encryption
- **External Secrets Operator**: Integration with HashiCorp Vault or cloud secret managers

Example locations requiring secrets:
- `infra/cert-manager-config/cloudflare-secret.yaml`
- Component-specific credentials in media-stack

### Customization

#### Modifying Helm Values

Edit the `values.yaml` file in the component directory:

```bash
# Example: Modify nginx-internal configuration
vi infra/nginx-ingress/internal/values.yaml
```

#### Adding New Applications

1. Create a new directory under `apps/`
2. Add Kubernetes manifests
3. Create a `fleet.yaml` file
4. Optionally create `kustomization.yaml` for manifest management
5. Update root `fleet.yaml` if needed

#### Adjusting Dependencies

Modify the `dependsOn` section in `fleet.yaml`:

```yaml
dependsOn:
  - name: homelab-rke2-infra-cert-manager
  - name: homelab-rke2-infra-nginx-ingress-internal
```

## Monitoring and Troubleshooting

### Check Fleet Status

```bash
# List all Fleet resources
kubectl get fleet -A

# Check specific bundle
kubectl get bundle -n fleet-default

# View bundle details
kubectl describe bundle <bundle-name> -n fleet-default
```

### Check Deployment Status

```bash
# Check cert-manager
kubectl get pods -n cert-manager

# Check ingress controllers
kubectl get pods -n ingress-internal
kubectl get pods -n ingress-external

# Check media stack
kubectl get pods -n media
```

### Common Issues

1. **Certificate Provisioning Failures**
   - Verify Cloudflare API credentials
   - Check cert-manager logs: `kubectl logs -n cert-manager deployment/cert-manager`
   - Verify DNS propagation

2. **Ingress Not Working**
   - Check ingress controller status
   - Verify DNS records point to LoadBalancer IP
   - Check certificate status: `kubectl get certificates -A`

3. **Fleet Bundle Not Deploying**
   - Check bundle status: `kubectl describe bundle <name> -n fleet-default`
   - Verify dependencies are met
   - Check for YAML syntax errors

## Maintenance

### Updating Component Versions

1. Edit the `fleet.yaml` file for the component
2. Update the `version` field
3. Commit and push changes
4. Fleet will automatically roll out the update

### Backup Strategy

Important resources to backup:
- PersistentVolume data (use Longhorn snapshots)
- Kubernetes secrets
- This Git repository
- Authentik database and configuration

## Security Considerations

- **Secrets**: Never commit unencrypted secrets to Git
- **Network Policies**: Consider implementing NetworkPolicies for pod-to-pod communication
- **RBAC**: Review and implement appropriate RBAC policies
- **Updates**: Regularly update Helm chart versions and container images
- **TLS**: All external services should use TLS certificates from cert-manager

## Contributing

1. Create a feature branch
2. Make changes
3. Test in a non-production environment
4. Submit a pull request
5. Review and merge

## License

This configuration is for personal homelab use.

## References

- [Rancher Fleet Documentation](https://fleet.rancher.io/)
- [RKE2 Documentation](https://docs.rke2.io/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [NGINX Ingress Controller](https://kubernetes.github.io/ingress-nginx/)
- [Kustomize Documentation](https://kustomize.io/)
