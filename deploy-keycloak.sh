#!/bin/bash

# Colors for better output
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Default values
NAMESPACE="keycloak"
RELEASE_NAME="keycloak"
VALUES_DIR="./helm"
CHART_REPO="codecentric/keycloak"
CHART_VERSION=""  # Empty means use the latest version
PROTOCOL="http"
DOMAIN="keycloak.example.com"
STATIC_IP_NAME=""
PROJECT_ID=""     # New parameter
REGION=""         # New parameter
SQL_INSTANCE=""   # New parameter
DEPLOYMENT_TYPE="loadbalancer" # Default deployment type

# Function to display usage information
usage() {
  echo -e "${BLUE}Usage:${NC} $0 [options]"
  echo -e "\nOptions:"
  echo -e "  ${GREEN}-n, --namespace${NC} NAMESPACE    Kubernetes namespace (default: keycloak)"
  echo -e "  ${GREEN}-r, --release${NC} RELEASE_NAME  Helm release name (default: keycloak)"
  echo -e "  ${GREEN}-c, --chart${NC} VALUES_DIR      Path to Helm chart directory (default: ./helm)"
  echo -e "  ${GREEN}-v, --version${NC} VERSION      Helm chart version (default: latest)"
  echo -e "  ${GREEN}-p, --protocol${NC} PROTOCOL     Protocol to use: http or https (default: http)"
  echo -e "  ${GREEN}-d|--domain${NC} DOMAIN         Domain name for KeycloakX (default: keycloak.example.com)"
  echo -e "  ${GREEN}-i|--ip-name${NC} IP_NAME       Name of the static IP in GCP (required for ingress)"
  echo -e "  ${GREEN}--project-id${NC} PROJECT_ID    GCP project ID (required)"
  echo -e "  ${GREEN}--region${NC} REGION          GCP region for Cloud SQL (required)"
  echo -e "  ${GREEN}--sql-instance${NC} INSTANCE    Cloud SQL instance name (required)"
  echo -e "  ${GREEN}--deployment-type${NC} TYPE   Deployment type: ingress or loadbalancer (default: ingress)"
  echo -e "  ${GREEN}-h, --help${NC}                 Display this help message"
  echo -e "\nExample:"
  echo -e "  $0 --protocol https --domain keycloak.mydomain.com --ip-name keycloak-static-ip \\"
  echo -e "     --project-id my-project-id --region us-central1 --sql-instance keycloak-db --version 18.1.0"
  echo -e "\nExample for LoadBalancer testing:"
  echo -e "  $0 --deployment-type loadbalancer --project-id my-project-id --region us-central1 --sql-instance keycloak-db"
  exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    -n|--namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    -r|--release)
      RELEASE_NAME="$2"
      shift 2
      ;;
    -c|--chart)
      VALUES_DIR="$2"
      shift 2
      ;;
    -v|--version)
      CHART_VERSION="$2"
      shift 2
      ;;
    -p|--protocol)
      PROTOCOL="$2"
      if [[ "$PROTOCOL" != "http" && "$PROTOCOL" != "https" ]]; then
        echo -e "${RED}Error:${NC} Protocol must be either 'http' or 'https'"
        exit 1
      fi
      shift 2
      ;;
    -d|--domain)
      DOMAIN="$2"
      shift 2
      ;;
    -i|--ip-name)
      STATIC_IP_NAME="$2"
      shift 2
      ;;
    --project-id)
      PROJECT_ID="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --sql-instance)
      SQL_INSTANCE="$2"
      shift 2
      ;;
    --deployment-type)
      DEPLOYMENT_TYPE="$2"
      if [[ "$DEPLOYMENT_TYPE" != "ingress" && "$DEPLOYMENT_TYPE" != "loadbalancer" ]]; then
        echo -e "${RED}Error:${NC} Deployment type must be either 'ingress' or 'loadbalancer'"
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo -e "${RED}Error:${NC} Unknown option: $1"
      usage
      ;;
  esac
done

# Validate required parameters
if [[ -z "$PROJECT_ID" ]]; then
  echo -e "${RED}Error:${NC} GCP project ID is required. Use --project-id to specify it."
  usage
fi

if [[ -z "$REGION" ]]; then
  echo -e "${RED}Error:${NC} GCP region is required. Use --region to specify it."
  usage
fi

if [[ -z "$SQL_INSTANCE" ]]; then
  echo -e "${RED}Error:${NC} Cloud SQL instance name is required. Use --sql-instance to specify it."
  usage
fi

# Static IP is required only for ingress deployment type
if [[ "$DEPLOYMENT_TYPE" == "ingress" && -z "$STATIC_IP_NAME" ]]; then
  echo -e "${RED}Error:${NC} Static IP name is required for ingress deployment type. Use --ip-name to specify it."
  usage
fi


# Function to check if a command exists
command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# Check for required tools
for cmd in kubectl helm; do
  if ! command_exists "$cmd"; then
    echo -e "${RED}Error:${NC} $cmd is not installed or not in PATH"
    exit 1
  fi
done

# Check if connected to a Kubernetes cluster
if ! kubectl cluster-info &>/dev/null; then
  echo -e "${RED}Error:${NC} Not connected to a Kubernetes cluster"
  exit 1
fi

# Create namespace if it doesn't exist
echo -e "\n${BLUE}Step 1:${NC} Creating namespace $NAMESPACE if it doesn't exist..."
if ! kubectl get namespace "$NAMESPACE" &>/dev/null; then
  kubectl create namespace "$NAMESPACE"
  echo -e "${GREEN}Namespace $NAMESPACE created${NC}"
else
  echo -e "${YELLOW}Namespace $NAMESPACE already exists${NC}"
fi


# Apply database credentials secret
echo -e "\n${BLUE}Step 2:${NC} Applying database credentials secret..."
if [[ -f "k8s/v1/Secret/keycloak-db-credentials.yaml" ]]; then
  kubectl apply -f "k8s/v1/Secret/keycloak-db-credentials.yaml"
  echo -e "${GREEN}Database credentials secret applied${NC}"
else
  echo -e "${RED}Error:${NC} Database credentials secret file not found at k8s/v1/Secret/keycloak-db-credentials.yaml"
  exit 1
fi

# Apply custom realm ConfigMap if it exists
# Inject app-realm.json into the ConfigMap
./inject-app-realm.sh

echo -e "\n${BLUE}Step 3:${NC} Applying custom realm ConfigMap..."
if [[ -f "k8s/v1/ConfigMap/custom-realm-config.yaml" ]]; then
  kubectl apply -f "k8s/v1/ConfigMap/custom-realm-config.yaml"
  echo -e "${GREEN}Custom realm ConfigMap applied${NC}"
else
  echo -e "${YELLOW}Warning:${NC} Custom realm ConfigMap file not found at k8s/v1/ConfigMap/custom-realm-config.yaml"
  echo -e "${YELLOW}Skipping this step. Make sure your values.yaml doesn't reference this ConfigMap.${NC}"
fi

# Update values.yaml with domain, static IP, Cloud SQL connection, and deployment type
echo -e "\n${BLUE}Step 4:${NC} Updating values.yaml with configuration..."
VALUES_FILE="$VALUES_DIR/values.yaml"

# Create a temporary file
TMP_VALUES=$(mktemp)

# Construct the Cloud SQL connection string
SQL_CONNECTION="$PROJECT_ID:$REGION:$SQL_INSTANCE"

# Update the values.yaml file
# Note: This sed approach is fragile. Consider using yq or a template engine for complex updates.

# Start by copying the original file to the temporary file
cat "$VALUES_FILE" > "$TMP_VALUES"

# Apply ingress-specific modifications if deployment type is ingress
if [[ "$DEPLOYMENT_TYPE" == "ingress" ]]; then
  echo -e "${BLUE}Applying ingress-specific values updates...${NC}"
  # Use a second temporary file for intermediate steps
  TMP_VALUES_INGRESS=$(mktemp)

  # Replace the default host with the specified domain
  cat "$TMP_VALUES" | \
    sed "s/host: \"keycloak\.example\.com\"/host: \"$DOMAIN\"/g" > "$TMP_VALUES_INGRESS"

  # Append the static IP annotation after the ingress class annotation
  cat "$TMP_VALUES_INGRESS" | \
    sed "/kubernetes\.io\/ingress\.class/a\\"$'\n'"    kubernetes.io/ingress.global-static-ip-name: \"$STATIC_IP_NAME\"" > "$TMP_VALUES"

  # Clean up the intermediate temporary file
  rm "$TMP_VALUES_INGRESS"
fi

# Apply Cloud SQL connection modification (needed for both types)
echo -e "${BLUE}Applying Cloud SQL connection values update...${NC}"
TMP_VALUES_SQL=$(mktemp)
cat "$TMP_VALUES" | \
  sed "s|- \"stellar-orb-451904-d9:asia-southeast2:spheres-sql-instance\"|- \"$SQL_CONNECTION\"|g" > "$TMP_VALUES_SQL"
mv "$TMP_VALUES_SQL" "$TMP_VALUES"


# Move the final temporary file back to the original location
mv "$TMP_VALUES" "$VALUES_FILE"

echo -e "${GREEN}Values file updated with:${NC}"
echo -e "  ${GREEN}Domain:${NC} $DOMAIN"
echo -e "  ${GREEN}Static IP:${NC} $STATIC_IP_NAME"
echo -e "  ${GREEN}Cloud SQL:${NC} $SQL_CONNECTION"
echo -e "  ${GREEN}Deployment Type:${NC} $DEPLOYMENT_TYPE"


# Install KeycloakX using Helm
echo -e "\n${BLUE}Step 5:${NC} Installing KeycloakX using Helm..."

# Prepare version flag if specified
VERSION_FLAG=""
if [[ -n "$CHART_VERSION" ]]; then
  VERSION_FLAG="--version $CHART_VERSION"
  echo -e "${BLUE}Using chart version:${NC} $CHART_VERSION"
fi

# Prepare set flags for Helm
SET_FLAGS=""
SET_FLAGS+=" --set deploymentType=$DEPLOYMENT_TYPE"
if [[ "$DEPLOYMENT_TYPE" == "ingress" ]]; then
  SET_FLAGS+=" --set ingress.enabled=true"
  SET_FLAGS+=" --set service.type=ClusterIP"
  if [[ "$PROTOCOL" == "https" ]]; then
    SET_FLAGS+=" --set https.enabled=true"
  else
    SET_FLAGS+=" --set https.enabled=false"
  fi
elif [[ "$DEPLOYMENT_TYPE" == "loadbalancer" ]]; then
  SET_FLAGS+=" --set ingress.enabled=false"
  SET_FLAGS+=" --set service.type=LoadBalancer"
  SET_FLAGS+=" --set https.enabled=false" # HTTPS is typically handled by Ingress or external LB
fi


# Install or upgrade the Helm chart
helm upgrade --install "$RELEASE_NAME" "$CHART_REPO" \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --values "$VALUES_FILE" \
  $VERSION_FLAG \
  $SET_FLAGS

if [[ $? -eq 0 ]]; then
  echo -e "${GREEN}KeycloakX installed successfully!${NC}"
else
  echo -e "${RED}Error:${NC} Failed to install KeycloakX"
  exit 1
fi

# Configure HTTPS if requested and using ingress
if [[ "$DEPLOYMENT_TYPE" == "ingress" && "$PROTOCOL" == "https" ]]; then
  echo -e "\n${BLUE}Step 6:${NC} Configuring HTTPS..."

  # Update the managed certificate with the correct domain
  CERT_FILE="k8s/networking.gke.io/ManagedCertificate/keycloak-certificate.yaml"
  TMP_CERT=$(mktemp)

  cat "$CERT_FILE" | \
    sed "s/- keycloak\.example\.com/- $DOMAIN/g" > "$TMP_CERT"

  mv "$TMP_CERT" "$CERT_FILE"

  # Apply the managed certificate
  kubectl apply -f "$CERT_FILE"


  # Update ingress annotations
  kubectl annotate ingress "$RELEASE_NAME" kubernetes.io/ingress.allow-http=false --overwrite -n "$NAMESPACE"
  kubectl annotate ingress "$RELEASE_NAME" networking.gke.io/managed-certificates=keycloak-certificate --overwrite -n "$NAMESPACE"

  echo -e "${GREEN}HTTPS configured successfully!${NC}"
  echo -e "${YELLOW}Note:${NC} It may take some time for the certificate to be provisioned and become active."
fi

# Wait for pods to be ready
echo -e "\n${BLUE}Step 7:${NC} Waiting for KeycloakX pods to be ready..."
kubectl rollout status statefulset "$RELEASE_NAME" -n "$NAMESPACE" --timeout=300s

# Display information about the deployment
echo -e "\n${BLUE}KeycloakX Deployment Summary:${NC}"
echo -e "${GREEN}Namespace:${NC} $NAMESPACE"
echo -e "${GREEN}Release Name:${NC} $RELEASE_NAME"
echo -e "${GREEN}Chart Version:${NC} ${CHART_VERSION:-latest}"
echo -e "${GREEN}Deployment Type:${NC} $DEPLOYMENT_TYPE"

if [[ "$DEPLOYMENT_TYPE" == "ingress" ]]; then
  echo -e "${GREEN}Protocol:${NC} $PROTOCOL"
  echo -e "${GREEN}Domain:${NC} $DOMAIN"
  echo -e "${GREEN}Static IP Name:${NC} $STATIC_IP_NAME"
  # Get the external IP
  EXTERNAL_IP=$(kubectl get ingress "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [[ -n "$EXTERNAL_IP" ]]; then
    echo -e "${GREEN}External IP (via Ingress):${NC} $EXTERNAL_IP"
    echo -e "\nYou can access KeycloakX at: ${BLUE}$PROTOCOL://$DOMAIN${NC}"
  else
    echo -e "${YELLOW}External IP not yet assigned to Ingress. Check the ingress status:${NC}"
    echo -e "kubectl get ingress \"$RELEASE_NAME\" -n \"$NAMESPACE\""
  fi
elif [[ "$DEPLOYMENT_TYPE" == "loadbalancer" ]]; then
  # Get the LoadBalancer IP
  EXTERNAL_IP=$(kubectl get service "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  if [[ -n "$EXTERNAL_IP" ]]; then
    echo -e "${GREEN}External IP (via LoadBalancer):${NC} $EXTERNAL_IP"
    echo -e "\nYou can access KeycloakX at: ${BLUE}http://$EXTERNAL_IP${NC}" # LoadBalancer typically uses HTTP unless configured otherwise
  else
    echo -e "${YELLOW}External IP not yet assigned to LoadBalancer service. Check the service status:${NC}"
    echo -e "kubectl get service \"$RELEASE_NAME\" -n \"$NAMESPACE\""
  fi
fi

echo -e "\n${GREEN}Deployment completed!${NC}"