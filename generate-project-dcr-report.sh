#!/usr/bin/env bash
#
# generate-project-dcr-report.sh
#
# Builds a DCR compliance report (du-branded, card-style layout) for one
# or more namespaces:
#   - Project Information header (Project Name, Jira No, Archer ID Demand,
#     Environment)
#   - DCR Validation compliance checklist - ONE SECTION PER NAMESPACE
#       (Status = Complaint/Non Complaint, Comment = fetched detail)
#
# Usage:
#   Multiple namespaces: ./generate-project-dcr-report.sh -N namespaces.txt -c project.conf [-o output.html]
#   Single namespace:     ./generate-project-dcr-report.sh -n <namespace>   -c project.conf [-o output.html]
#
# project.conf format (bash-sourced):
#   PROJECT_NAME="Order Service Migration"
#   JIRA_NO="REQ12345"
#   ARCHER_ID="DEM6789"
#   ENVIRONMENT="DR"
#
# namespaces.txt format (one per line, "#" for comments):
#   ccairtime
#   order-service-prod
#
# Requirements: oc or kubectl configured against the target cluster.

set -uo pipefail

NAMESPACE_SINGLE=""
NAMESPACES_FILE=""
CONF_FILE=""
OUTPUT_FILE=""
CLI=""

usage() {
    cat <<EOF
Usage:
  Multiple namespaces: $0 -N <namespaces.txt> -c <project.conf> [-o output.html]
  Single namespace:     $0 -n <namespace>      -c <project.conf> [-o output.html]

Options:
  -n   Single namespace to validate (use instead of -N)
  -N   Path to namespaces list file, one per line (use instead of -n)
  -c   Path to project config file (Project Name/Jira No/etc.) (required)
  -o   Output HTML file (default: project-dcr-report.html)
  -h   Show this help message
EOF
    exit 1
}

while getopts "n:N:c:o:h" opt; do
    case "$opt" in
        n) NAMESPACE_SINGLE="$OPTARG" ;;
        N) NAMESPACES_FILE="$OPTARG" ;;
        c) CONF_FILE="$OPTARG" ;;
        o) OUTPUT_FILE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

[[ -z "$NAMESPACE_SINGLE" && -z "$NAMESPACES_FILE" ]] && { echo "Error: pass -n <namespace> or -N <namespaces.txt>." >&2; usage; }
[[ -n "$NAMESPACE_SINGLE" && -n "$NAMESPACES_FILE" ]] && { echo "Error: use only one of -n or -N." >&2; usage; }
[[ -z "$CONF_FILE" ]] && { echo "Error: -c <project.conf> is required." >&2; usage; }
[[ ! -f "$CONF_FILE" ]] && { echo "Error: config file '$CONF_FILE' not found." >&2; exit 1; }
[[ -n "$NAMESPACES_FILE" && ! -f "$NAMESPACES_FILE" ]] && { echo "Error: namespaces file '$NAMESPACES_FILE' not found." >&2; exit 1; }

OUTPUT_FILE="${OUTPUT_FILE:-project-dcr-report.html}"

# ------------------------------
# Build the list of namespaces to process
# ------------------------------
declare -a NAMESPACES
if [[ -n "$NAMESPACE_SINGLE" ]]; then
    NAMESPACES=("$NAMESPACE_SINGLE")
else
    while IFS= read -r line; do
        line=$(echo "$line" | xargs)
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        NAMESPACES+=("$line")
    done < "$NAMESPACES_FILE"
fi

if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
    echo "Error: no namespaces to process." >&2
    exit 1
fi

# ------------------------------
# Load project metadata
# ------------------------------
PROJECT_NAME=""
JIRA_NO=""
ARCHER_ID=""
ENVIRONMENT=""
# shellcheck disable=SC1090
source "$CONF_FILE"

# ------------------------------
# Detect oc/kubectl
# ------------------------------
detect_cli() {
    if command -v oc &>/dev/null; then
        CLI="oc"
    elif command -v kubectl &>/dev/null; then
        CLI="kubectl"
    else
        echo "Error: neither 'oc' nor 'kubectl' found in PATH." >&2
        exit 1
    fi
}

validate_namespaces() {
    local ns valid=()
    for ns in "${NAMESPACES[@]}"; do
        if $CLI get ns "$ns" &>/dev/null; then
            valid+=("$ns")
        else
            echo "Warning: namespace '$ns' not found or not accessible - skipping." >&2
        fi
    done
    NAMESPACES=("${valid[@]}")
    if [[ ${#NAMESPACES[@]} -eq 0 ]]; then
        echo "Error: none of the given namespaces are accessible." >&2
        exit 1
    fi
}

# ==================================================================
# DCR Compliance checklist - per namespace
# ==================================================================

get_resource_quota() {
    local ns="$1" out
    out=$($CLI get resourcequota -n "$ns" --no-headers 2>/dev/null)
    [[ -z "$out" ]] && return
    local detail
    detail=$($CLI get resourcequota -n "$ns" -o json 2>/dev/null | \
        python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
parts = []
for item in d.get("items", []):
    name = item["metadata"]["name"]
    hard = item.get("status", {}).get("hard", {})
    kv = ", ".join(f"{k}={v}" for k, v in hard.items())
    parts.append(f"{name}: {kv}")
print(" | ".join(parts))
' 2>/dev/null)
    [[ -n "$detail" ]] && echo "$detail" || echo "$out" | awk '{print $1}' | paste -sd ', ' -
}

get_egress_details() {
    local ns="$1"
    [[ "$CLI" != "oc" ]] && return
    local out
    out=$(oc get egressip -o json 2>/dev/null | \
        python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ns='${ns}'
found = []
for item in d.get('items', []):
    sel = item.get('spec', {}).get('namespaceSelector', {}).get('matchLabels', {})
    if sel.get('name') == ns:
        found.append(', '.join(item.get('spec', {}).get('egressIPs', [])))
print(' | '.join(found))
" 2>/dev/null)
    if [[ -n "$out" ]]; then
        echo "$out"
    else
        local netns_egress
        netns_egress=$(oc get netnamespace "$ns" -o jsonpath='{.egressIPs}' 2>/dev/null)
        [[ -n "$netns_egress" && "$netns_egress" != "[]" ]] && echo "$netns_egress"
    fi
}

get_storage_details() {
    local ns="$1" scs pvcs result
    scs=$($CLI get storageclass -o custom-columns=NAME:.metadata.name,PROVISIONER:.provisioner --no-headers 2>/dev/null | \
        awk '{printf "%s (%s)\n", $1, $2}' | paste -sd '; ' -)
    pvcs=$($CLI get pvc -n "$ns" --no-headers 2>/dev/null | \
        awk '{printf "%s -> %s\n", $1, $6}' | paste -sd '; ' -)
    result=""
    [[ -n "$scs" ]] && result="${scs}"
    if [[ -n "$pvcs" ]]; then
        [[ -n "$result" ]] && result="${result} || PVCs: ${pvcs}" || result="PVCs: ${pvcs}"
    fi
    echo "$result"
}

get_node_labels() {
    local ns="$1"
    $CLI get ns "$ns" -o jsonpath='{.metadata.annotations.openshift\.io/node-selector}' 2>/dev/null
}

get_role_bindings() {
    local ns="$1"
    $CLI get rolebindings -n "$ns" --no-headers 2>/dev/null | \
        awk '{printf "%s (role=%s)\n", $1, $2}' | paste -sd '; ' -
}

get_elk_dependency() {
    local ns="$1"
    $CLI get deployment,statefulset,daemonset -n "$ns" -o json 2>/dev/null | \
        grep -io 'elk\|elasticsearch\|logstash\|kibana' | sort -u | paste -sd ', ' -
}

# ELK check has INVERTED logic vs. the other checks: finding a dependency
# means NON-COMPLIANT, finding nothing means COMPLIANT.
status_for_elk() {
    local hits="$1"
    [[ -z "$hits" ]] && echo "Complaint" || echo "Non Complaint"
}

comment_for_elk() {
    local hits="$1"
    if [[ -z "$hits" ]]; then
        echo "No dependency on infra ELK/Elasticsearch cluster found"
    else
        echo "Dependency found on: ${hits}"
    fi
}

status_for() {
    [[ -n "$1" ]] && echo "Complaint" || echo "Non Complaint"
}

# Associative array keyed "namespace::field" to hold comments per namespace
declare -A NS_COMMENTS

collect_dcr_data_for_namespace() {
    local ns="$1"
    echo "Fetching DCR compliance details for namespace '$ns'..." >&2
    NS_COMMENTS["${ns}::quota"]="$(get_resource_quota "$ns")"
    NS_COMMENTS["${ns}::egress"]="$(get_egress_details "$ns")"
    NS_COMMENTS["${ns}::storage"]="$(get_storage_details "$ns")"
    NS_COMMENTS["${ns}::nodes"]="$(get_node_labels "$ns")"
    NS_COMMENTS["${ns}::roles"]="$(get_role_bindings "$ns")"
    NS_COMMENTS["${ns}::elk"]="$(get_elk_dependency "$ns")"
}

collect_all_dcr_data() {
    local ns
    for ns in "${NAMESPACES[@]}"; do
        collect_dcr_data_for_namespace "$ns"
    done
}

# ==================================================================
# Console summary
# ==================================================================

print_console_report() {
    echo
    echo "===================================================================================="
    echo " Project Information"
    echo "===================================================================================="
    echo "Project Name    : $PROJECT_NAME"
    echo "Jira No         : $JIRA_NO"
    echo "Archer ID Demand: $ARCHER_ID"
    echo "Environment     : $ENVIRONMENT"
    echo "Namespaces      : ${NAMESPACES[*]}"

    local ns sno action comment status
    for ns in "${NAMESPACES[@]}"; do
        echo
        echo "===================================================================================="
        echo " DCR Validation Details - Namespace: $ns"
        echo "===================================================================================="
        printf "%-4s %-55s %-15s %s\n" "S.No" "Action" "Status" "Comment"
        printf '%s\n' "------------------------------------------------------------------------------------------------"

        # Static rows: always "Complaint", no fetch/validation performed.
        local static_rows=(
            "1|\"DCR Validation for Total Namespace resource allocation and quota (Infra team will be validating entire project only not on individual pod/deployment as this will be keep changing based on application design)\"|Complaint|"
            "2|Backup Strategy to be aligned with back up team and ensure name space ,stateful,stateless configuraitons are  backed up|Complaint|Backup is available it will configured once application pod is deployed"
        )
        for row in "${static_rows[@]}"; do
            IFS='|' read -r sno action status comment <<< "$row"
            printf "%-4s %-55s %-15s %s\n" "$sno" "$action" "$status" "$comment"
        done

        local rows=(
            "3|Resource Quota to be enabled with resource restriction.|${NS_COMMENTS[${ns}::quota]}"
            "5|Egress details for application to be shared|${NS_COMMENTS[${ns}::egress]}"
            "6|Storage Details to be shared|${NS_COMMENTS[${ns}::storage]}"
            "7|Node Labels/selectors to be ensured for each project|${NS_COMMENTS[${ns}::nodes]}"
            "12|Namespace admin and namespace view roles to be defined for each project|${NS_COMMENTS[${ns}::roles]}"
        )
        for row in "${rows[@]}"; do
            IFS='|' read -r sno action comment <<< "$row"
            status=$(status_for "$comment")
            printf "%-4s %-55s %-15s %s\n" "$sno" "$action" "$status" "$comment"
        done

        # Row 18 (ELK) uses inverted logic: no dependency found = Complaint.
        local elk_hits="${NS_COMMENTS[${ns}::elk]}"
        local elk_status elk_comment
        elk_status=$(status_for_elk "$elk_hits")
        elk_comment=$(comment_for_elk "$elk_hits")
        printf "%-4s %-55s %-15s %s\n" "18" "Application should not be depending on infra ELK cluster" "$elk_status" "$elk_comment"
    done
    echo "===================================================================================="
}

# ==================================================================
# HTML report (du-branded card-style layout)
# ==================================================================

html_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

build_dcr_html_rows_for_ns() {
    local ns="$1"
    local sno action comment status status_class row_html=""

    # Static rows: always "Complaint", no fetch/validation performed.
    # These are informational/process items, not something the cluster
    # can confirm or deny, so they render fixed on every run.
    local static_rows=(
        "1|\"DCR Validation for Total Namespace resource allocation and quota (Infra team will be validating entire project only not on individual pod/deployment as this will be keep changing based on application design)\"|Complaint|"
        "2|Backup Strategy to be aligned with back up team and ensure name space ,stateful,stateless configuraitons are  backed up|Complaint|Backup is available it will configured once application pod is deployed"
    )
    for row in "${static_rows[@]}"; do
        IFS='|' read -r sno action status comment <<< "$row"
        row_html+="        <tr>
          <td class=\"sno\">${sno}</td>
          <td class=\"action\">$(echo "$action" | html_escape)</td>
          <td class=\"status complaint\">${status}</td>
          <td class=\"comment\">$(echo "$comment" | html_escape)</td>
          <td class=\"col1\">applicable</td>
        </tr>
"
    done

    local rows=(
        "3|Resource Quota to be enabled with resource restriction.|${NS_COMMENTS[${ns}::quota]}"
        "5|Egress details for application to be shared|${NS_COMMENTS[${ns}::egress]}"
        "6|Storage Details to be shared|${NS_COMMENTS[${ns}::storage]}"
        "7|Node Labels/selectors  to be ensured for each project|${NS_COMMENTS[${ns}::nodes]}"
        "12|Namespace admin and namespace view roles to be defined for each project (Project admin have full provilge on project resource)|${NS_COMMENTS[${ns}::roles]}"
    )
    for row in "${rows[@]}"; do
        IFS='|' read -r sno action comment <<< "$row"
        status=$(status_for "$comment")
        [[ "$status" == "Complaint" ]] && status_class="complaint" || status_class="non-complaint"
        row_html+="        <tr>
          <td class=\"sno\">${sno}</td>
          <td class=\"action\">$(echo "$action" | html_escape)</td>
          <td class=\"status ${status_class}\">${status}</td>
          <td class=\"comment\">$(echo "$comment" | html_escape)</td>
          <td class=\"col1\">applicable</td>
        </tr>
"
    done

    # Row 18 (ELK) uses inverted logic: no dependency found = Complaint.
    local elk_hits="${NS_COMMENTS[${ns}::elk]}"
    local elk_status elk_comment elk_class
    elk_status=$(status_for_elk "$elk_hits")
    elk_comment=$(comment_for_elk "$elk_hits")
    [[ "$elk_status" == "Complaint" ]] && elk_class="complaint" || elk_class="non-complaint"
    row_html+="        <tr>
          <td class=\"sno\">18</td>
          <td class=\"action\">Application should not be depending on infra ELK cluster</td>
          <td class=\"status ${elk_class}\">${elk_status}</td>
          <td class=\"comment\">$(echo "$elk_comment" | html_escape)</td>
          <td class=\"col1\">applicable</td>
        </tr>
"

    echo "$row_html"
}

build_toc() {
    local ns html=""
    for ns in "${NAMESPACES[@]}"; do
        html+="          <li><a href=\"#ns-$(echo "$ns" | tr -c 'a-zA-Z0-9' '-')\">$(echo "$ns" | html_escape)</a></li>
"
    done
    echo "$html"
}

build_all_dcr_sections() {
    local ns html=""
    for ns in "${NAMESPACES[@]}"; do
        local anchor rows_html
        anchor=$(echo "$ns" | tr -c 'a-zA-Z0-9' '-')
        rows_html="$(build_dcr_html_rows_for_ns "$ns")"
        html+="    <div class=\"section\">
        <div class=\"section-title\" id=\"ns-${anchor}\">DCR Validation &mdash; Namespace: $(echo "$ns" | html_escape)</div>
        <table>
          <thead>
            <tr>
              <th>S.NO</th><th>Action</th><th>Status</th><th>Comment</th><th>Column1</th>
            </tr>
          </thead>
          <tbody>
${rows_html}          </tbody>
        </table>
    </div>
"
    done
    echo "$html"
}

generate_html_report() {
    local toc_html dcr_sections_html
    toc_html="$(build_toc)"
    dcr_sections_html="$(build_all_dcr_sections)"

    cat <<EOF > "$OUTPUT_FILE"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>DCR Validation Report - ${PROJECT_NAME}</title>
<style>
    body {
        font-family: Arial, sans-serif;
        background-color: #f4f6f9;
        margin: 20px;
    }
    .container {
        max-width: 100%;
        margin: auto;
        background: #ffffff;
        border-radius: 10px;
        box-shadow: 0 2px 10px rgba(0,0,0,0.1);
        overflow: hidden;
    }

    .header {
        background: #0078D4;
        color: white;
        padding: 20px;
        text-align: center;
        font-size: 28px;
        font-weight: bold;
    }

    .section {
        padding: 20px;
    }

    .section-title {
        background: #28a745;
        color: white;
        padding: 10px;
        border-radius: 5px;
        margin-bottom: 15px;
        font-size: 18px;
        font-weight: bold;
    }

    .info-table {
        width: 100%;
        border-collapse: collapse;
        margin-bottom: 20px;
    }

    .info-table td {
        padding: 12px;
        border: 1px solid #ddd;
    }

    .label {
        background: #005A9E;
        color: white;
        font-weight: bold;
        width: 25%;
    }

    .value {
        background: #f8f9fa;
    }

    .toc {
        background: #f8f9fa;
        border: 1px solid #ddd;
        border-radius: 6px;
        padding: 12px 20px;
        margin-bottom: 10px;
    }
    .toc ul { margin: 6px 0 0 0; }
    .toc a { color: #005A9E; text-decoration: none; }
    .toc a:hover { text-decoration: underline; }

    table {
        border-collapse: collapse;
        width: 100%;
        background: #fff;
    }
    th, td {
        border: 1px solid #444;
        padding: 8px 10px;
        vertical-align: top;
        font-size: 13px;
        word-break: break-word;
    }
    thead th {
        background: #000;
        color: #fff;
        text-align: center;
    }
    td.sno { text-align: center; width: 4%; }
    td.action { width: 38%; }
    td.status { width: 12%; font-weight: bold; text-align: center; }
    td.status.complaint { color: #1a73e8; }
    td.status.non-complaint { color: #d93025; }
    td.comment { width: 34%; color: #1a4d80; }
    td.col1 { background: #1e9e50; color: #fff; text-align: center; font-weight: bold; width: 12%; }
    tr:nth-child(even) { background: #fafafa; }

    .footer {
        text-align: center;
        padding: 15px;
        background: #f0f0f0;
        color: #666;
    }
</style>
</head>
<body>

<div class="container">

    <div class="header">
        du Project Infra Details
    </div>

    <div class="section">
        <div class="section-title">Project Information</div>

        <table class="info-table">
            <tr>
                <td class="label">Project Name</td>
                <td class="value">$(echo "$PROJECT_NAME" | html_escape)</td>
                <td class="label">Jira No</td>
                <td class="value">$(echo "$JIRA_NO" | html_escape)</td>
            </tr>
            <tr>
                <td class="label">Archer ID Demand</td>
                <td class="value">$(echo "$ARCHER_ID" | html_escape)</td>
                <td class="label">Environment</td>
                <td class="value">$(echo "$ENVIRONMENT" | html_escape)</td>
            </tr>
        </table>

        <div class="toc">
          <strong>Namespaces in this report:</strong>
          <ul>
${toc_html}          </ul>
        </div>
    </div>

${dcr_sections_html}
    <div class="footer">
        Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')
    </div>

</div>
</body>
</html>
EOF
    echo "HTML report generated: $OUTPUT_FILE"
}

# ==================================================================
# Main
# ==================================================================

main() {
    detect_cli
    validate_namespaces
    collect_all_dcr_data
    print_console_report
    generate_html_report
}

main
