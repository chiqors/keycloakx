#!/bin/bash
JSON_FILE="k8s/v1/ConfigMap/app-realm.json"
CONFIGMAP_TEMPLATE="k8s/v1/ConfigMap/custom-realm-config.yaml.template"
CONFIGMAP_OUTPUT="k8s/v1/ConfigMap/custom-realm-config.yaml"

sed '/app-realm.json: |/q' "$CONFIGMAP_TEMPLATE" > "$CONFIGMAP_OUTPUT"
echo "" >> "$CONFIGMAP_OUTPUT"
INDENT="      " # 6 spaces
sed "s/^/$INDENT/" "$JSON_FILE" >> "$CONFIGMAP_OUTPUT"