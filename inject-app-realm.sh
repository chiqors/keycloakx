#!/bin/bash
set -euo pipefail # Exit on error, unset var, pipefail

# --- Configuration ---
JSON_FILE_PATH="k8s/v1/ConfigMap/app-realm.json"
# Template for the ConfigMap that will include the realm JSON
CONFIGMAP_TEMPLATE_PATH="k8s/v1/ConfigMap/custom-realm-config.yaml.template"
# Output path for the generated ConfigMap YAML
CONFIGMAP_OUTPUT_PATH="k8s/v1/ConfigMap/custom-realm-config.yaml"
# The key in the ConfigMap where the realm JSON will be stored
REALM_JSON_KEY="app-realm.json" # This must match the key in custom-realm-config.yaml.template

# Colors for output
BLUE="\033[0;34m"
GREEN="\033[0;32m"
RED="\033[0;31m"
NC="\033[0m"

log_info() { echo -e "${BLUE}INFO:${NC} $1"; }
log_success() { echo -e "${GREEN}SUCCESS:${NC} $1"; }
log_error() { echo -e "${RED}ERROR:${NC} $1"; exit 1; }

# --- Sanity Checks ---
if [[ ! -f "$JSON_FILE_PATH" ]]; then
  log_error "Realm JSON file not found: $JSON_FILE_PATH"
fi

if [[ ! -f "$CONFIGMAP_TEMPLATE_PATH" ]]; then
  log_error "ConfigMap template file not found: $CONFIGMAP_TEMPLATE_PATH"
fi

# --- Main Logic ---
log_info "Starting injection of '$JSON_FILE_PATH' into '$CONFIGMAP_TEMPLATE_PATH' to create '$CONFIGMAP_OUTPUT_PATH'..."

# Ensure the output directory exists
mkdir -p "$(dirname "$CONFIGMAP_OUTPUT_PATH")"

# Prepare the indentation (6 spaces as per original script)
INDENTATION_STRING="      "

# Use awk to process the template. When the marker is found,
# awk will read and indent the JSON file line by line.
awk -v key_marker_line="  $REALM_JSON_KEY: |" \
    -v json_to_inject="$JSON_FILE_PATH" \
    -v indent_prefix="$INDENTATION_STRING" '
BEGIN {
  found_marker = 0;
}
{
  print; # Print the current line from the template
}
# Check if the current line from the template matches our key_marker_line
$0 == key_marker_line {
  found_marker = 1; # Set marker as soon as the line is matched

  # Marker found. Now read the JSON file, indent each line, and print.
  # The `getline` function reads from the file specified.
  # It returns 1 on success, 0 on EOF, -1 on error.
  # If the file json_to_inject cannot be opened, getline returns -1,
  # the while condition (-1 > 0) is false, and the loop is skipped.
  while ( (getline line < json_to_inject) > 0 ) {
    print indent_prefix line;
  }
  # Important: close the file after reading.
  # This should be done regardless of whether the loop executed or not,
  # as long as an attempt to read might have occurred.
  close(json_to_inject);
}
END {
  if (found_marker == 0) {
    print "ERROR: Marker line '\''" key_marker_line "'\'' not found in template '\''" ARGV[1] "'\''." > "/dev/stderr";
    # ARGV[1] is the first filename argument to awk, which is CONFIGMAP_TEMPLATE_PATH
    # Force a non-zero exit for the shell script to catch
    exit 1
  }
}
' "$CONFIGMAP_TEMPLATE_PATH" > "$CONFIGMAP_OUTPUT_PATH"

# Check awk's exit status
AWK_EXIT_STATUS=$?
if [[ $AWK_EXIT_STATUS -ne 0 ]]; then
    # Awk script itself would have printed an error to stderr if marker not found or other awk error.
    log_error "Awk script failed with exit status $AWK_EXIT_STATUS. This might be due to the marker not being found in the template, or an issue reading the JSON file."
fi

log_success "Successfully injected '$JSON_FILE_PATH' into '$CONFIGMAP_OUTPUT_PATH'."
log_info "Make sure '$REALM_JSON_KEY: |' in '$CONFIGMAP_TEMPLATE_PATH' (preceded by two spaces) is correctly formatted for the injection."
