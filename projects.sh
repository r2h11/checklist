#!/usr/bin/env bash
#
# create-openshift-project.sh
#
# Automates OpenShift project creation including:
#   - Project creation
#   - Namespace labeling
#   - EgressIP assignment
#   - AD group sync
#   - Role binding
#
# Usage:
#   ./create-openshift-project.sh -p ccairtime -d "Project for testing apps" \
#       -n "My Test Project" -e 172.16.4.6 \
#       -g "CN=ccairtime,OU=Global Security,OU=Groups,OU=Corp,DC=corp,DC=ae" \
#       -l corp.du.ae:389 -o corp.ae -r admin
#
# Run with -h for full help.

set -euo pipefail

# ------------------------------
# Defaults
# ------------------------------
PROJECT_NAME=""
PROJECT_DESC="Project for testing apps"
PROJECT_DISPLAY_NAME=""
EGRESS_IP=""
LDAP_UID=""
LDAP_URL="corp.du.ae:389"
LDAP_HOST="corp.ae"
ROLE="admin"
WORKDIR="$(mktemp -d)"

usage() {
    cat <<EOF
Usage: $0 -p <project_name> [options]

Required:
  -p  Project (namespace) name                 e.g. ccairtime

Optional:
  -d  Project description                      (default: "$PROJECT_DESC")
  -n  Project display name                     (default: same as project name)
  -e  Egress IP address                        e.g. 172.16.4.6
  -g  LDAP group DN for AD sync                 e.g. "CN=ccairtime,OU=Global Security,OU=Groups,OU=Corp,DC=corp,DC=ae"
  -l  LDAP URL                                  (default: "$LDAP_URL")
  -o  LDAP host label                           (default: "$LDAP_HOST")
  -r  Role to bind to the AD group              (default: "$ROLE")
  -h  Show this help message

Example:
  $0 -p ccairtime -d "Project for testing apps" -n "My Test Project" \\
     -e 172.16.4.6 \\
     -g "CN=ccairtime,OU=Global Security,OU=Groups,OU=Corp,DC=corp,DC=ae" \\
     -r admin
EOF
    exit 1
}

# ------------------------------
# Parse arguments
# ------------------------------
while getopts "p:d:n:e:g:l:o:r:h" opt; do
    case "$opt" in
        p) PROJECT_NAME="$OPTARG" ;;
        d) PROJECT_DESC="$OPTARG" ;;
        n) PROJECT_DISPLAY_NAME="$OPTARG" ;;
        e) EGRESS_IP="$OPTARG" ;;
        g) LDAP_UID="$OPTARG" ;;
        l) LDAP_URL="$OPTARG" ;;
        o) LDAP_HOST="$OPTARG" ;;
        r) ROLE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$PROJECT_NAME" ]]; then
    echo "Error: project name (-p) is required." >&2
    usage
fi

PROJECT_DISPLAY_NAME="${PROJECT_DISPLAY_NAME:-$PROJECT_NAME}"

log() {
    echo -e "\n==> $1"
}

check_oc() {
    if ! command -v oc &>/dev/null; then
        echo "Error: 'oc' CLI not found in PATH." >&2
        exit 1
    fi
    if ! oc whoami &>/dev/null; then
        echo "Error: not logged in to an OpenShift cluster. Run 'oc login' first." >&2
        exit 1
    fi
}

# ------------------------------
# Step 1: Project Creation
# ------------------------------
create_project() {
    log "Creating project '$PROJECT_NAME'..."
    if oc get project "$PROJECT_NAME" &>/dev/null; then
        echo "Project '$PROJECT_NAME' already exists. Skipping creation."
    else
        oc new-project "$PROJECT_NAME" \
            --description="$PROJECT_DESC" \
            --display-name="$PROJECT_DISPLAY_NAME"
    fi
}

# ------------------------------
# Step 2: Label the namespace
# ------------------------------
label_namespace() {
    log "Labeling namespace '$PROJECT_NAME'..."
    oc label namespace "$PROJECT_NAME" name="$PROJECT_NAME" --overwrite
}

# ------------------------------
# Step 3: EgressIP assignment
# ------------------------------
assign_egress_ip() {
    if [[ -z "$EGRESS_IP" ]]; then
        echo "No egress IP provided (-e). Skipping EgressIP assignment."
        return
    fi

    log "Assigning EgressIP '$EGRESS_IP' to namespace '$PROJECT_NAME'..."
    cat <<EOF > "$WORKDIR/egressip-${PROJECT_NAME}.yaml"
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: egressip-${PROJECT_NAME}
spec:
  egressIPs:
  - ${EGRESS_IP}
  namespaceSelector:
    matchLabels:
      name: ${PROJECT_NAME}
EOF
    oc apply -f "$WORKDIR/egressip-${PROJECT_NAME}.yaml"
}

# ------------------------------
# Step 4: Sync AD group
# ------------------------------
sync_ad_group() {
    if [[ -z "$LDAP_UID" ]]; then
        echo "No LDAP group DN provided (-g). Skipping AD group sync."
        return
    fi

    log "Creating/syncing AD group '$PROJECT_NAME'..."
    cat <<EOF > "$WORKDIR/group-${PROJECT_NAME}.yaml"
apiVersion: user.openshift.io/v1
kind: Group
metadata:
  annotations:
    openshift.io/ldap.uid: ${LDAP_UID}
    openshift.io/ldap.url: ${LDAP_URL}
  labels:
    openshift.io/ldap.host: ${LDAP_HOST}
  name: ${PROJECT_NAME}
users:
EOF
    oc apply -f "$WORKDIR/group-${PROJECT_NAME}.yaml"
}

# ------------------------------
# Step 5: Role binding
# ------------------------------
create_rolebinding() {
    log "Binding role '$ROLE' to group '$PROJECT_NAME'..."
    oc adm policy add-role-to-group "$ROLE" "$PROJECT_NAME" -n "$PROJECT_NAME"
}

# ------------------------------
# Main
# ------------------------------
main() {
    check_oc
    create_project
    label_namespace
    assign_egress_ip
    sync_ad_group
    create_rolebinding

    log "Done. Generated manifests (if any) are in: $WORKDIR"
    echo "Project '$PROJECT_NAME' setup complete."
}

main
