#!/usr/bin/env bash
#
# openstack_validation_checklist.sh
# ---------------------------------
# Builds a validation checklist PER INSTANCE for an OpenStack (OSP) project.
# Each instance gets its own HTML checklist containing both sections:
#   1. Validation Points          (project + that instance's nova/cinder data)
#   2. OS Level Validation Points (that instance's in-guest data)
# An index.html links them all together.
#
# Usage : ./openstack_validation_checklist.sh -p <project> [-c <cloud-name>]
#                                             [-n <cluster-name>] [-o <outdir>]
#                                             [-s <ssh-user>] [-i <instance>]
#   -p  Project (tenant) name or ID                       (required)
#   -c  Cloud name from clouds.yaml (else source the RC file first)
#   -n  OSP cluster / overcloud name shown in the report  (default: derived)
#   -o  Output directory                                  (default: ./validation)
#   -s  SSH user for OS-level checks                      (default: skip)
#   -i  Limit to one instance (name or ID); repeatable
#
# Requires: python3-openstackclient, jq. OS-level checks also need ssh.
#
set -uo pipefail

PROJECT=""; CLOUD=""; CLUSTER=""; OUTDIR="./validation"; SSH_USER=""
declare -a ONLY=()
while getopts ":p:c:n:o:s:i:h" opt; do
  case $opt in
    p) PROJECT="$OPTARG" ;;
    c) CLOUD="$OPTARG" ;;
    n) CLUSTER="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    s) SSH_USER="$OPTARG" ;;
    i) ONLY+=("$OPTARG") ;;
    h) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done
[[ -z "$PROJECT" ]] && { echo "ERROR: -p <project> is required. Use -h for help." >&2; exit 1; }

command -v openstack >/dev/null || { echo "ERROR: openstack CLI not found." >&2; exit 1; }
command -v jq        >/dev/null || { echo "ERROR: jq not found." >&2; exit 1; }

OS_OPTS=()
[[ -n "$CLOUD" ]] && OS_OPTS+=(--os-cloud "$CLOUD")
os() { openstack "${OS_OPTS[@]}" "$@" 2>/dev/null; }

TS=$(date +%Y%m%d_%H%M%S)
STAMP=$(date '+%Y-%m-%d %H:%M:%S')
SAFE=$(echo "$PROJECT" | tr -c 'A-Za-z0-9._-' '_')
RUNDIR="$OUTDIR/${SAFE}_${TS}"
mkdir -p "$RUNDIR" || { echo "ERROR: cannot create $RUNDIR" >&2; exit 1; }
NA="Not Available"

esc() { echo "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
blank_if_empty() { local v; v=$(cat); [[ -z "${v//[[:space:]]/}" ]] && echo "$NA" || echo "$v"; }

CSS='body{font-family:Calibri,Arial,sans-serif;font-size:12px;margin:18px}
table{border-collapse:collapse;width:100%;table-layout:fixed}
td,th{border:1px solid #000;padding:3px 5px;vertical-align:top;word-wrap:break-word}
.sec{background:#F4B183;font-weight:bold;text-align:center}
.hdr{background:#D9D9D9;font-weight:bold;text-align:center}
col.c1{width:26%}col.c2{width:32%}col.c3{width:21%}col.c4{width:21%}
h2{margin:0 0 4px;font-size:16px} .meta{color:#444;margin:0 0 12px}
a{color:#1155cc}'

r() { # r <desc> <result> <remarks> <expected>
  { echo "<tr><td>$(esc "$1")</td><td>$(esc "${2:-$NA}")</td>"
    echo "<td>$(esc "${3:-}")</td><td>$(esc "${4:-}")</td></tr>"; } >> "$FILE"
}
banner() {
  echo "<tr><td class='sec' colspan='4'>$(esc "$1")</td></tr>" >> "$FILE"
  echo "<tr><td class='hdr'>Validation Description</td><td class='hdr'>Result</td><td class='hdr'>Remarks</td><td class='hdr'>Excepted result</td></tr>" >> "$FILE"
}

echo ">> Reading project '$PROJECT' ..."

# ---------------------------------------------------- project-wide context ---
PROJ_JSON=$(os project show "$PROJECT" -f json)
[[ -z "$PROJ_JSON" ]] && { echo "ERROR: project '$PROJECT' not found or no permission." >&2; exit 2; }
PROJ_ID=$(jq -r '.id'   <<<"$PROJ_JSON")
PROJ_NAME=$(jq -r '.name' <<<"$PROJ_JSON")
PROJ_DOM=$(jq -r '.domain_id // "default"' <<<"$PROJ_JSON")

if [[ -z "$CLUSTER" ]]; then
  AUTH=${OS_AUTH_URL:-}
  [[ -z "$AUTH" && -n "$CLOUD" ]] && AUTH="cloud:$CLOUD"
  CLUSTER=$(sed -E 's#https?://##; s#[:/].*##' <<<"${AUTH:-$NA}")
fi

QUOTA=$(os quota show "$PROJ_ID" -f json)
q() { jq -r --arg k "$1" '.[$k] // "-"' <<<"$QUOTA"; }
QUOTA_TXT="vCPU: $(q cores) | RAM(MB): $(q ram) | Instances: $(q instances) | Volumes: $(q volumes) | Gigabytes: $(q gigabytes) | Snapshots: $(q snapshots) | Floating IPs: $(q floating_ips) | Sec-Groups: $(q secgroups) | Networks: $(q networks) | Ports: $(q ports)"

SERVERS=$(os server list --project "$PROJ_ID" --long -f json); [[ -z "$SERVERS" ]] && SERVERS='[]'
TOTAL=$(jq 'length' <<<"$SERVERS")
RUNNING=$(jq '[.[]|select(.Status=="ACTIVE")]|length' <<<"$SERVERS")
PROJ_COUNT="Total: $TOTAL | ACTIVE: $RUNNING | Other: $((TOTAL-RUNNING))"

AGGS=$(os aggregate list --long -f json);                             [[ -z "$AGGS"   ]] && AGGS='[]'
FIPS=$(os floating ip list --project "$PROJ_ID" -f json);             [[ -z "$FIPS"   ]] && FIPS='[]'
SNAPS=$(os volume snapshot list --project "$PROJ_ID" --long -f json); [[ -z "$SNAPS"  ]] && SNAPS='[]'
IMAGES=$(os image list --private --long -f json);                     [[ -z "$IMAGES" ]] && IMAGES='[]'

if [[ ${#ONLY[@]} -gt 0 ]]; then
  FILTER=$(printf '%s\n' "${ONLY[@]}" | jq -R . | jq -sc .)
  SERVERS=$(jq --argjson f "$FILTER" '[.[]|select((.Name as $n|$f|index($n)) or (.ID as $i|$f|index($i)))]' <<<"$SERVERS")
fi
COUNT=$(jq 'length' <<<"$SERVERS")
[[ "$COUNT" -eq 0 ]] && { echo "No matching instances in project '$PROJ_NAME'." >&2; exit 3; }
echo ">> $COUNT instance(s) to document."

os_check() { [[ -z "$SSH_USER" || -z "${1:-}" ]] && { echo ""; return; }
  timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "${SSH_USER}@${1}" "$2" 2>/dev/null | tr '\n' ' '; }

declare -a INDEX=()

# ================================ per instance ===============================
while IFS=$'\t' read -r SID SNAME SSTAT SFLAV SHOST SNET; do
  [[ -z "$SID" ]] && continue
  echo "   - $SNAME"
  FSAFE=$(echo "$SNAME" | tr -c 'A-Za-z0-9._-' '_')
  FILE="$RUNDIR/${FSAFE}.html"
  DETAIL=$(os server show "$SID" -f json); [[ -z "$DETAIL" ]] && DETAIL='{}'
  IP=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<<"$SNET" | tail -1)

  {
    echo "<html><head><meta charset='utf-8'><title>Validation - $(esc "$SNAME")</title><style>$CSS</style></head><body>"
    echo "<h2>Validation Checklist &ndash; $(esc "$SNAME")</h2>"
    echo "<p class='meta'>Project: $(esc "$PROJ_NAME") &nbsp;|&nbsp; Cluster: $(esc "$CLUSTER") &nbsp;|&nbsp; Instance ID: $(esc "$SID") &nbsp;|&nbsp; Status: $(esc "$SSTAT") &nbsp;|&nbsp; Generated: $STAMP &nbsp;|&nbsp; <a href='index.html'>&laquo; all instances</a></p>"
    echo "<table><col class='c1'><col class='c2'><col class='c3'><col class='c4'>"
  } > "$FILE"

  banner "Validation Points"

  r "OpenStack Cluster name" "$CLUSTER" "Keystone endpoint / overcloud" "Same cluster as source"
  r "Project Name on OSP" "$PROJ_NAME (ID: $PROJ_ID)" "Domain: $PROJ_DOM" "Project exists and enabled"
  r "Project Quota details" "$QUOTA_TXT" "openstack quota show" "Quota sufficient for all workloads"
  r "No. of Running Instances in Project" "$PROJ_COUNT" "Project-wide count" "All instances ACTIVE post activity"
  r "Instances Hostname" "$SNAME" "Nova instance name | status: $SSTAT" "Hostname unchanged"
  r "Instances Flavors used in Instances" "$SFLAV" \
    "$(jq -r 'if (.flavor|type)=="object" then "vCPU:\(.flavor.vcpus // "-") RAM:\(.flavor.ram // "-")MB Disk:\(.flavor.disk // "-")GB" else "" end' <<<"$DETAIL")" \
    "Flavor matches source"

  VOLS=$(jq -r '(.volumes_attached // .volumes // []) | if type=="array" then [.[]|(.id // .)]|join(" ") else tostring end' <<<"$DETAIL")
  VTXT=""; VIDS=()
  for V in $VOLS; do
    [[ -z "$V" || "$V" == "null" ]] && continue
    VIDS+=("$V")
    VD=$(os volume show "$V" -f json)
    VTXT+="$(jq -r '"\(.name // .id)(\(.size)GB/\(.volume_type // "-")/\(.status))"' <<<"$VD"), "
  done
  ROOT=$(jq -r '.image // "-" | if type=="object" then (.name // "-") else . end' <<<"$DETAIL")
  r "Instances Volume / Disk details" "root: $ROOT | ${VTXT:-no cinder volume attached}" \
    "Attached volumes: ${#VIDS[@]}" "All volumes attached & in-use"

  r "Instances Network Name/Subnet Associated" \
    "$(jq -r '(.addresses // {}) | if type=="object" then [to_entries[]|"\(.key): \(.value|join(","))"]|join(" | ") else tostring end' <<<"$DETAIL" | blank_if_empty)" \
    "Network = IP mapping" "Same network/subnet and IP retained"

  AGG=$(jq -r --arg h "$SHOST" '[.[]|select((.Hosts//[])|index($h))|.Name]|join(",")' <<<"$AGGS")
  AZ=$(jq -r '.["OS-EXT-AZ:availability_zone"] // "-"' <<<"$DETAIL")
  r "Host Aggregrate Group if any" "${SHOST:-$NA}${AGG:+ [agg: $AGG]}" "AZ: $AZ" "Instance lands in correct aggregate/AZ"

  MIG=$(os server migration list --server "$SID" -f json); [[ -z "$MIG" ]] && MIG='[]'
  L=$(jq '[.[]|select((.Type//""|ascii_downcase)=="live-migration")]|length' <<<"$MIG" 2>/dev/null || echo 0)
  C=$(jq '[.[]|select((.Type//""|ascii_downcase)|test("resize|^migration$"))]|length' <<<"$MIG" 2>/dev/null || echo 0)
  LAST=$(jq -r 'if length>0 then (sort_by(.["Updated At"]//"")|last|.["Updated At"]//"-") else "-" end' <<<"$MIG" 2>/dev/null || echo "-")
  r "Live Migrations of Instances" "${L:-0}" "Last migration event: $LAST" "Live migration completes, no downtime"
  r "Cold Migrations of Instances" "${C:-0}" "Resize / cold migration count" "Cold migration completes, instance ACTIVE"

  SNAPTXT=""
  for V in ${VIDS[@]+"${VIDS[@]}"}; do
    SNAPTXT+="$(jq -r --arg v "$V" '[.[]|select((.["Volume ID"]//.volume_id//"")==$v)|"\(.Name)(\(.Size)GB,\(.Status))"]|join(", ")' <<<"$SNAPS") "
  done
  r "Volume Snapshots" "$(echo "$SNAPTXT" | blank_if_empty)" "Snapshots of this instance's volumes" "Snapshots present and available"

  r "Instance Image backup" \
    "$(jq -r --arg n "$SNAME" --arg p "$PROJ_ID" '[.[]|select((.Owner//"")==$p and ((.Name//"")|test($n;"i")))|"\(.Name)(\(.Status))"]|join(", ")' <<<"$IMAGES" | blank_if_empty)" \
    "Images owned by project matching name" "Backup image exists and active"

  IPLIST=$(jq -r '(.addresses//{})|if type=="object" then [.[][]]|join(" ") else tostring end' <<<"$DETAIL")
  r "Instance Floating IP's" \
    "$(jq -r --arg ips "$IPLIST" '[.[]|select(($ips|split(" "))|index(.["Fixed IP Address"]//"x"))|"\(.["Floating IP Address"]) -> \(.["Fixed IP Address"])"]|join(", ")' <<<"$FIPS" | blank_if_empty)" \
    "Mapped to this instance's fixed IP" "Same floating IP re-associated"

  r "Project Security Group" \
    "$(jq -r '(.security_groups // []) | if type=="array" then [.[]|(.name // .)]|join(", ") else tostring end' <<<"$DETAIL" | blank_if_empty)" \
    "Groups attached to this instance" "All SGs and rules intact"

  if echo "$ROOT" | grep -Eqi 'ova|custom|imported|p2v|v2v'; then OVA="$ROOT (likely custom/OVA)"; else OVA="$NA"; fi
  r "Instances OVA Custome OS if any" "$OVA" "Heuristic on image name - verify manually" "Custom/OVA image boots correctly"

  # ---------------------------- OS level ----------------------------
  banner "OS Level Validation Points"

  OSV=$(os_check "$IP" ". /etc/os-release 2>/dev/null; echo \$PRETTY_NAME \$(uname -r)")
  r "Installed OS version" "${OSV:-$NA}" "${SSH_USER:+via ssh $IP}" "Same OS + kernel as before"

  OSH=$(os_check "$IP" "hostname -f")
  if [[ -n "$OSH" ]]; then
    if [[ "${OSH%% *}" == "$SNAME"* ]]; then M="MATCH"; else M="MISMATCH"; fi
    r "OS hostname and Instance are same" "$OSH - $M" "Nova name: $SNAME" "OS hostname == Nova instance name"
  else
    r "OS hostname and Instance are same" "$NA" "Nova name: $SNAME" "OS hostname == Nova instance name"
  fi

  r "OS level cluster configured" \
    "$(os_check "$IP" "pcs status 2>/dev/null | head -3 || crm status 2>/dev/null | head -3 || systemctl is-active pacemaker corosync 2>/dev/null" | blank_if_empty)" \
    "pcs / crm / pacemaker" "Cluster online, all nodes joined"
  r "DB is running" \
    "$(os_check "$IP" "systemctl is-active mysqld mariadb postgresql 2>/dev/null | paste -sd, -; ps -ef | grep -Ec '[m]ysqld|[p]ostgres|[o]ra_pmon'" | blank_if_empty)" \
    "Service state + process count" "DB service active and accepting connections"
  r "DB level cluster is configured" \
    "$(os_check "$IP" "pcs resource show 2>/dev/null | grep -Ei 'sql|db|galera' | head -3; systemctl is-active garbd galera 2>/dev/null" | blank_if_empty)" \
    "galera / DB resource in cluster" "DB cluster healthy, replication in sync"

  echo '</table></body></html>' >> "$FILE"
  INDEX+=("$FSAFE.html|$SNAME|$SSTAT|${IP:-$NA}|$SFLAV|${SHOST:-$NA}")
done < <(jq -r '.[]|"\(.ID)\t\(.Name)\t\(.Status)\t\(.Flavor)\t\(.Host // .["Compute Host"] // "")\t\(.Networks|tostring)"' <<<"$SERVERS")

# ------------------------------------------------------------------ index ----
{
  echo "<html><head><meta charset='utf-8'><title>Validation - $(esc "$PROJ_NAME")</title><style>$CSS</style></head><body>"
  echo "<h2>Validation Checklists &ndash; $(esc "$PROJ_NAME")</h2>"
  echo "<p class='meta'>Cluster: $(esc "$CLUSTER") &nbsp;|&nbsp; $PROJ_COUNT &nbsp;|&nbsp; Generated: $STAMP</p>"
  echo "<table><col class='c1'><col class='c2'><col class='c3'><col class='c4'>"
  echo "<tr><td class='sec' colspan='4'>Instances</td></tr>"
  echo "<tr><td class='hdr'>Instance</td><td class='hdr'>Status / IP</td><td class='hdr'>Flavor</td><td class='hdr'>Compute Host</td></tr>"
  for I in "${INDEX[@]}"; do
    IFS='|' read -r F N S IPX FL H <<<"$I"
    echo "<tr><td><a href='$(esc "$F")'>$(esc "$N")</a></td><td>$(esc "$S") / $(esc "$IPX")</td><td>$(esc "$FL")</td><td>$(esc "$H")</td></tr>"
  done
  echo "</table></body></html>"
} > "$RUNDIR/index.html"

echo
echo "Done. ${#INDEX[@]} checklist(s) written to: $RUNDIR"
echo "  Start here: $RUNDIR/index.html"
[[ -z "$SSH_USER" ]] && echo "  Note: OS-level rows left as '$NA' (no -s <ssh-user> given)."
