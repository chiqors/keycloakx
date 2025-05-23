# KeycloakX on GKE Autopilot

This repository contains configuration and deployment scripts for running KeycloakX on Google Kubernetes Engine (GKE) Autopilot with RBAC, external Cloud SQL database connectivity, and custom realm setup.

## Project Structure

```
├── deploy-keycloak.sh       # Main deployment script
├── toggle-https.sh          # Script to enable/disable HTTPS
├── helm/                    # Helm chart directory
│   └── values.yaml          # KeycloakX Helm values configuration
└── k8s/                     # Kubernetes resource definitions
    ├── networking.gke.io/   # GKE-specific resources
    │   └── ManagedCertificate/
    │       └── keycloak-certificate.yaml  # Managed certificate for HTTPS
    └── v1/                  # Kubernetes core resources
        ├── ConfigMap/       # ConfigMaps directory
        │   └── custom-realm-config.yaml  # Custom realm configuration
        └── Secret/          # Secrets directory
            └── keycloak-db-credentials.yaml  # Database credentials
```

## Prerequisites

- Google Kubernetes Engine (GKE) Autopilot cluster
- Cloud SQL PostgreSQL instance
- Static IP address in GCP
- Domain name (for HTTPS)
- `kubectl` and `helm` installed and configured

## Configuration

### Database Credentials

The database credentials are stored in a Kubernetes Secret at `k8s/v1/Secret/keycloak-db-credentials.yaml`. The default values are:

- Username: `keycloak` (base64 encoded)
- Password: (base64 encoded)

### Custom Realm

A custom realm can be configured using the ConfigMap at `k8s/v1/ConfigMap/custom-realm-config.yaml`. This will be automatically imported during KeycloakX startup.

### Helm Values

The `helm/values.yaml` file contains the configuration for the KeycloakX Helm chart, including:

- Image configuration
- RBAC settings
- Service account configuration
- HTTP settings
- Database configuration
- Cloud SQL proxy configuration
- Ingress and HTTPS settings
- Resource requests and limits

## Deployment

The `deploy-keycloak.sh` script automates the deployment process. It handles:

1. Creating the namespace
2. Applying database credentials
3. Applying custom realm configuration
4. Updating values.yaml with domain, static IP, and Cloud SQL connection
5. Installing KeycloakX using Helm
6. Configuring HTTPS (if requested)
7. Waiting for pods to be ready

### Usage

```bash
./deploy-keycloak.sh [options]
```

### Options

- `-n, --namespace NAMESPACE`: Kubernetes namespace (default: keycloak)
- `-r, --release RELEASE_NAME`: Helm release name (default: keycloak)
- `-c, --chart CHART_DIR`: Path to Helm chart directory (default: ./helm)
- `-v, --version VERSION`: Helm chart version (default: latest)
- `-p, --protocol PROTOCOL`: Protocol to use: http or https (default: http)
- `-d, --domain DOMAIN`: Domain name for KeycloakX (default: keycloak.example.com)
- `-i, --ip-name IP_NAME`: Name of the static IP in GCP (required)
- `--project-id PROJECT_ID`: GCP project ID (required)
- `--region REGION`: GCP region for Cloud SQL (required)
- `--sql-instance INSTANCE`: Cloud SQL instance name (required)
- `-h, --help`: Display help message

### Example

```bash
./deploy-keycloak.sh --protocol https \
  --domain keycloak.mydomain.com \
  --ip-name keycloak-static-ip \
  --project-id my-project-id \
  --region us-central1 \
  --sql-instance keycloak-db \
  --version 18.1.0
```

## HTTPS Configuration

HTTPS can be enabled during deployment by setting the protocol to `https`. This will:

1. Update the managed certificate with your domain
2. Apply the certificate to your cluster
3. Configure the ingress to use HTTPS

You can also toggle HTTPS after deployment using the `toggle-https.sh` script:

```bash
# Enable HTTPS
./toggle-https.sh enable

# Disable HTTPS
./toggle-https.sh disable
```

## Accessing KeycloakX

After deployment, KeycloakX will be accessible at:

```
http(s)://your-domain.com
```

The deployment script will display the external IP and access URL upon completion.

## Troubleshooting

### Certificate Provisioning

It may take some time (up to 60 minutes) for the managed certificate to be provisioned and become active. During this time, you may see certificate warnings in your browser.

### Connection Issues

If you're having trouble connecting to KeycloakX, check the ingress status:

```bash
kubectl get ingress keycloak -n keycloak
```

### Pod Status

To check the status of the KeycloakX pods:

```bash
kubectl get pods -n keycloak
kubectl logs -l app=keycloak -n keycloak
```

## Maintenance

### Updating KeycloakX

To update KeycloakX to a new version, run the deployment script with the desired version:

```bash
./deploy-keycloak.sh --version NEW_VERSION [other options]
```

### Scaling

By default, KeycloakX is deployed with 1 replica. To scale, modify the `replicas` value in `helm/values.yaml` before deployment.