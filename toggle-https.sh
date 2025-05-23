#!/bin/bash

if [ "$1" == "enable" ]; then
  echo "Enabling HTTPS for KeycloakX..."
  # Apply the managed certificate
  kubectl apply -f k8s/networking.gke.io/ManagedCertificate/keycloak-certificate.yaml
  
  # Update ingress annotations
  kubectl annotate ingress keycloak kubernetes.io/ingress.allow-http=false --overwrite
  kubectl annotate ingress keycloak networking.gke.io/managed-certificates=keycloak-certificate --overwrite
  
  echo "HTTPS enabled successfully!"
elif [ "$1" == "disable" ]; then
  echo "Disabling HTTPS for KeycloakX..."
  # Remove HTTPS annotations
  kubectl annotate ingress keycloak kubernetes.io/ingress.allow-http- networking.gke.io/managed-certificates-
  
  # Delete the managed certificate
  kubectl delete -f k8s/networking.gke.io/ManagedCertificate/keycloak-certificate.yaml
  
  echo "HTTPS disabled successfully!"
else
  echo "Usage: ./toggle-https.sh [enable|disable]"
  exit 1
fi