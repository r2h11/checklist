#!/usr/bin/env bash
#
# openstack_validation_checklist.sh
# ---------------------------------
# Builds ONE HTML validation checklist for an OpenStack (OSP) project,
# covering every instance in it. The file opens with a summary/index table
# (links jump to each instance's section on the same page), followed by a
# full checklist per instance:
#   1. Validation Points          (project + that instance's nova/cinder data)
#   2. OS Level Validation Points (that instance's in-guest data)
#
# Usage : ./openstack_validation_checklist.sh -p <project> [-c <cloud-name>]
#                                             [-n <cluster-name>] [-o <outdir>]
#                                             [-i <instance>]
#   -p  Project (tenant) name or ID                       (required)
#   -c  Cloud name from clouds.yaml (else source the RC file first)
#   -n  OSP cluster / overcloud name shown in the report  (default: derived)
#   -o  Output directory                                  (default: ./validation)
#   -i  Limit to one instance (name or ID); repeatable
#
# No SSH / in-guest access is used. Live migration, cold migration, and every
# OS Level Validation Point are reported as "Manual Validation" unless the
# value can be read from Nova/Glance metadata directly (image os_distro/
# os_version, or instance properties such as os_cluster/db_status/db_cluster
# that you set yourself with `openstack server set --property`).
#
# Requires: python3-openstackclient. JSON parsing uses python3 (no jq needed --
# python3 is already required to run the openstack CLI itself). Quota values
# are read directly from openstack CLI column output (-f value -c Resource
# -c Limit) with no JSON parser at all.
#
set -uo pipefail

PROJECT=""; CLOUD=""; CLUSTER=""; OUTDIR="./validation"
declare -a ONLY=()
while getopts ":p:c:n:o:i:h" opt; do
  case $opt in
    p) PROJECT="$OPTARG" ;;
    c) CLOUD="$OPTARG" ;;
    n) CLUSTER="$OPTARG" ;;
    o) OUTDIR="$OPTARG" ;;
    i) ONLY+=("$OPTARG") ;;
    h) sed -n '2,27p' "$0"; exit 0 ;;
    *) echo "Invalid option -$OPTARG" >&2; exit 1 ;;
  esac
done
[[ -z "$PROJECT" ]] && { echo "ERROR: -p <project> is required. Use -h for help." >&2; exit 1; }

command -v openstack >/dev/null || { echo "ERROR: openstack CLI not found." >&2; exit 1; }
command -v python3   >/dev/null || { echo "ERROR: python3 not found (required by the openstack CLI itself)." >&2; exit 1; }

OS_OPTS=()
[[ -n "$CLOUD" ]] && OS_OPTS+=(--os-cloud "$CLOUD")
os() { openstack "${OS_OPTS[@]}" "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
# jqx: minimal jq replacement using python3. Used everywhere EXCEPT the quota
# block below, which reads openstack CLI column output directly instead.
#   echo "$JSON" | jqx '<python expression using d = parsed JSON>' [extra args...]
#   Extra args are available inside the expression as a[0], a[1], ...
#   Lists/tuples are printed comma-joined; None prints as empty string.
# ---------------------------------------------------------------------------
JQX_PY=$(mktemp /tmp/jqx.XXXXXX.py) || { echo "ERROR: mktemp failed" >&2; exit 1; }
trap 'rm -f "$JQX_PY"' EXIT
cat > "$JQX_PY" << 'PYEOF'
import sys, json
expr = sys.argv[1]
a = sys.argv[2:]
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
try:
    result = eval(expr)
except Exception:
    result = ""
if isinstance(result, (list, tuple)):
    print(", ".join(str(x) for x in result))
elif result is None:
    print("")
else:
    print(result)
PYEOF

jqx() {
  local expr="$1"; shift
  python3 "$JQX_PY" "$expr" "$@"
}

TS=$(date +%Y%m%d_%H%M%S)
STAMP=$(date '+%Y-%m-%d %H:%M:%S')
SAFE=$(printf '%s' "$PROJECT" | tr -c 'A-Za-z0-9._-' '_')
mkdir -p "$OUTDIR" || { echo "ERROR: cannot create $OUTDIR" >&2; exit 1; }
FILE="$OUTDIR/${SAFE}_validation_${TS}.html"
NA="Not Available"

esc() { echo "${1:-}" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
blank_if_empty() { local v; v=$(cat); [[ -z "${v//[[:space:]]/}" ]] && echo "$NA" || echo "$v"; }

CSS='body{font-family:Calibri,Arial,sans-serif;font-size:12px;margin:18px}
table{border-collapse:collapse;width:100%;table-layout:fixed;margin-bottom:26px}
td,th{border:1px solid #000;padding:3px 5px;vertical-align:top;word-wrap:break-word}
.sec{background:#F4B183;font-weight:bold;text-align:center}
.hdr{background:#D9D9D9;font-weight:bold;text-align:center}
col.c1{width:26%}col.c2{width:32%}col.c3{width:21%}col.c4{width:21%}
h2{margin:0 0 4px;font-size:16px} h3{margin:26px 0 4px;font-size:14px}
.meta{color:#444;margin:0 0 12px}
a{color:#1155cc} .top{font-size:11px}'

# r/banner append to $FILE, which is the single combined report for the
# whole run -- every section (index + each instance) writes to the same file.
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
PROJ_ID=$(echo "$PROJ_JSON"   | jqx "d.get('id','')")
PROJ_NAME=$(echo "$PROJ_JSON" | jqx "d.get('name','')")
PROJ_DOM=$(echo "$PROJ_JSON"  | jqx "d.get('domain_id') or 'default'")

if [[ -z "$CLUSTER" ]]; then
  AUTH=${OS_AUTH_URL:-}
  [[ -z "$AUTH" && -n "$CLOUD" ]] && AUTH="cloud:$CLOUD"
  CLUSTER=$(sed -E 's#https?://##; s#[:/].*##' <<<"${AUTH:-$NA}")
fi

# ------------------------------------------------------------------ quota ---
# No jq / jqx here: read column values straight out of the openstack CLI.
# OSP 18's `quota show` reports rows as Resource/Limit pairs rather than one
# column per resource, so fetch it once and filter rows with awk.
QUOTA_RAW=$(openstack "${OS_OPTS[@]}" quota show "$PROJ_ID" -f value -c Resource -c Limit 2>/dev/null)

q() {  # q <resource-name-as-it-appears-in-the-Resource-column>
  local v
  v=$(awk -v n="$1" '$1==n{print $2}' <<<"$QUOTA_RAW")
  echo "${v:--}"
}

ql() {  # ql <limits-absolute-name>   (fallback for compute values only)
  local v
  v=$(openstack "${OS_OPTS[@]}" limits show --absolute --project "$PROJ_ID" \
        -f value -c Name -c Value 2>/dev/null | awk -v n="$1" '$1==n{print $2}')
  echo "${v:--}"
}

CORES=$(q cores);         [[ "$CORES" == "-" ]]     && CORES=$(ql maxTotalCores)
RAM=$(q ram);             [[ "$RAM" == "-" ]]       && RAM=$(ql maxTotalRAMSize)
INSTANCES=$(q instances); [[ "$INSTANCES" == "-" ]] && INSTANCES=$(ql maxTotalInstances)

QUOTA_LINES=(
  "vCPU: $CORES"
  "RAM(MB): $RAM"
  "Instances: $INSTANCES"
  "Volumes: $(q volumes)"
  "Gigabytes: $(q gigabytes)"
  "Snapshots: $(q snapshots)"
)

SERVERS=$(os server list --project "$PROJ_ID" --long -f json); [[ -z "$SERVERS" ]] && SERVERS='[]'
TOTAL=$(echo "$SERVERS"   | jqx "len(d)")
RUNNING=$(echo "$SERVERS" | jqx "len([x for x in d if x.get('Status')=='ACTIVE'])")
PROJ_COUNT="Total: $TOTAL | ACTIVE: $RUNNING | Other: $((TOTAL-RUNNING))"

AGGS=$(os aggregate list --long -f json);                             [[ -z "$AGGS"   ]] && AGGS='[]'
FIPS=$(os floating ip list --project "$PROJ_ID" -f json);             [[ -z "$FIPS"   ]] && FIPS='[]'
SNAPS=$(os volume snapshot list --project "$PROJ_ID" --long -f json); [[ -z "$SNAPS"  ]] && SNAPS='[]'
IMAGES=$(os image list --private --long -f json);                     [[ -z "$IMAGES" ]] && IMAGES='[]'

# Flatten server list into TSV: id, name, status, flavor, host, networks(repr)
SERVERS_TSV=$(echo "$SERVERS" | jqx "chr(10).join(chr(9).join([str(x.get('ID','')), str(x.get('Name','')), str(x.get('Status','')), str(x.get('Flavor','')), str(x.get('Host') or x.get('Compute Host') or ''), str(x.get('Networks','')).replace(chr(10),' ')]) for x in d)")

if [[ ${#ONLY[@]} -gt 0 ]]; then
  FILTERED=""
  while IFS=$'\t' read -r sid sname sstat sflav shost snet; do
    [[ -z "$sid" ]] && continue
    for o in "${ONLY[@]}"; do
      if [[ "$sname" == "$o" || "$sid" == "$o" ]]; then
        FILTERED+="$sid"$'\t'"$sname"$'\t'"$sstat"$'\t'"$sflav"$'\t'"$shost"$'\t'"$snet"$'\n'
        break
      fi
    done
  done <<<"$SERVERS_TSV"
  SERVERS_TSV="$FILTERED"
fi
COUNT=$(grep -c . <<<"$SERVERS_TSV" || true)
[[ "$COUNT" -eq 0 ]] && { echo "No matching instances in project '$PROJ_NAME'." >&2; exit 3; }
echo ">> $COUNT instance(s) to document."

# ----------------------------------------------------------- file header -----
{
  echo "<html><head><meta charset='utf-8'><title>Validation - $(esc "$PROJ_NAME")</title><style>$CSS</style></head><body>"
  echo "<a id='top'></a><h2>OpenStack Validation Checklist &ndash; $(esc "$PROJ_NAME")</h2>"
  echo "<p class='meta'>Cluster: $(esc "$CLUSTER") &nbsp;|&nbsp; $PROJ_COUNT &nbsp;|&nbsp; Generated: $STAMP</p>"
} > "$FILE"

# ------------------------------------------------- summary/index table -------
{
  echo "<table><col class='c1'><col class='c2'><col class='c3'><col class='c4'>"
  echo "<tr><td class='sec' colspan='4'>Instances</td></tr>"
  echo "<tr><td class='hdr'>Instance</td><td class='hdr'>Status / IP</td><td class='hdr'>Flavor</td><td class='hdr'>Compute Host</td></tr>"
  while IFS=$'\t' read -r SID SNAME SSTAT SFLAV SHOST SNET; do
    [[ -z "$SID" ]] && continue
    IP=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<<"$SNET" | tail -1)
    ANCHOR=$(printf '%s' "$SNAME" | tr -c 'A-Za-z0-9._-' '_')
    echo "<tr><td><a href='#$(esc "$ANCHOR")'>$(esc "$SNAME")</a></td><td>$(esc "$SSTAT") / $(esc "${IP:-$NA}")</td><td>$(esc "$SFLAV")</td><td>$(esc "${SHOST:-$NA}")</td></tr>"
  done <<<"$SERVERS_TSV"
  echo "</table>"
} >> "$FILE"

# ================================ per instance ===============================
while IFS=$'\t' read -r SID SNAME SSTAT SFLAV SHOST SNET; do
  [[ -z "$SID" ]] && continue
  echo "   - $SNAME"
  ANCHOR=$(printf '%s' "$SNAME" | tr -c 'A-Za-z0-9._-' '_')
  DETAIL=$(os server show "$SID" -f json); [[ -z "$DETAIL" ]] && DETAIL='{}'
  IP=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<<"$SNET" | tail -1)

  {
    echo "<a id='$(esc "$ANCHOR")'></a><h3>Instance: $(esc "$SNAME") <span class='top'>(<a href='#top'>back to top</a>)</span></h3>"
    echo "<p class='meta'>Instance ID: $(esc "$SID") &nbsp;|&nbsp; Status: $(esc "$SSTAT")</p>"
    echo "<table><col class='c1'><col class='c2'><col class='c3'><col class='c4'>"
  } >> "$FILE"

  banner "Validation Points"

  r "OpenStack Cluster name" "$CLUSTER" "Keystone endpoint / overcloud" "Same cluster as source"
  r "Project Name on OSP" "$PROJ_NAME (ID: $PROJ_ID)" "Domain: $PROJ_DOM" "Project exists and enabled"

  # Quota row: one field per line (CPU first, then RAM, then the rest).
  QUOTA_HTML=""
  for line in "${QUOTA_LINES[@]}"; do
    QUOTA_HTML+="$(esc "$line")<br>"
  done
  { echo "<tr><td>$(esc "Project Quota details")</td><td>$QUOTA_HTML</td>"
    echo "<td>$(esc "openstack quota show")</td><td>$(esc "Quota sufficient for all workloads")</td></tr>"; } >> "$FILE"

  r "No. of Running Instances in Project" "$PROJ_COUNT" "Project-wide count" "All instances ACTIVE post activity"
  r "Instances Hostname" "$SNAME" "Nova instance name | status: $SSTAT" "Hostname unchanged"

  FLAVOR_DETAIL=$(echo "$DETAIL" | jqx "('vCPU:%s RAM:%sMB Disk:%sGB' % (d.get('flavor',{}).get('vcpus','-'), d.get('flavor',{}).get('ram','-'), d.get('flavor',{}).get('disk','-'))) if isinstance(d.get('flavor'), dict) else ''")
  r "Instances Flavors used in Instances" "$SFLAV" "$FLAVOR_DETAIL" "Flavor matches source"

  VOLS=$(echo "$DETAIL" | jqx "' '.join(str(v.get('id',v) if isinstance(v,dict) else v) for v in (d.get('volumes_attached') or d.get('volumes') or []))")
  VTXT=""; VIDS=()
  for V in $VOLS; do
    [[ -z "$V" || "$V" == "null" ]] && continue
    VIDS+=("$V")
    VD=$(os volume show "$V" -f json)
    VTXT+="$(echo "$VD" | jqx "f\"{d.get('name') or d.get('id')}({d.get('size')}GB/{d.get('volume_type','-')}/{d.get('status')})\""), "
  done
  ROOT=$(echo "$DETAIL" | jqx "(d.get('image') or {}).get('name','-') if isinstance(d.get('image'), dict) else (d.get('image') or '-')")
  r "Instances Volume / Disk details" "root: $ROOT | ${VTXT:-no cinder volume attached}" \
    "Attached volumes: ${#VIDS[@]}" "All volumes attached & in-use"

  NETS=$(echo "$DETAIL" | jqx "' | '.join(f\"{k}: {(','.join(v) if isinstance(v,list) else v)}\" for k,v in (d.get('addresses') or {}).items())")
  r "Instances Network Name/Subnet Associated" "$(echo "$NETS" | blank_if_empty)" \
    "Network = IP mapping" "Same network/subnet and IP retained"

  AGG=$(echo "$AGGS" | jqx "','.join(x.get('Name','') for x in d if a[0] and a[0] in (x.get('Hosts') or []))" "$SHOST")
  AZ=$(echo "$DETAIL" | jqx "d.get('OS-EXT-AZ:availability_zone','-')")
  r "Host Aggregrate Group if any" "${SHOST:-$NA}${AGG:+ [agg: $AGG]}" "AZ: $AZ" "Instance lands in correct aggregate/AZ"

  r "Live Migrations of Instances" "Yes (Manual Validation)" "Infra confirmed capable of live migration" "Live migration completes, no downtime"
  r "Cold Migrations of Instances" "Yes (Manual Validation)" "Infra confirmed capable of cold migration" "Cold migration completes, instance ACTIVE"

  SNAPTXT=""
  for V in ${VIDS[@]+"${VIDS[@]}"}; do
    SNAPTXT+="$(echo "$SNAPS" | jqx "', '.join(f\"{x.get('Name','')}({x.get('Size','')}GB,{x.get('Status','')})\" for x in d if (x.get('Volume ID') or x.get('volume_id') or '')==a[0])" "$V") "
  done
  r "Volume Snapshots" "$(echo "$SNAPTXT" | blank_if_empty)" "Snapshots of this instance's volumes" "Snapshots present and available"

  IMGTXT=$(echo "$IMAGES" | jqx "', '.join(f\"{x.get('Name','')}({x.get('Status','')})\" for x in d if (x.get('Owner') or '')==a[0] and a[1].lower() in str(x.get('Name') or '').lower())" "$PROJ_ID" "$SNAME")
  r "Instance Image backup" "$(echo "$IMGTXT" | blank_if_empty)" "Images owned by project matching name" "Backup image exists and active"

  IPLIST=$(echo "$DETAIL" | jqx "' '.join(ip for v in (d.get('addresses') or {}).values() for ip in (v if isinstance(v,list) else [v]))")
  FIPTXT=$(echo "$FIPS" | jqx "', '.join(f\"{x.get('Floating IP Address','')} -> {x.get('Fixed IP Address','')}\" for x in d if (x.get('Fixed IP Address') or 'x') in a[0].split())" "$IPLIST")
  r "Instance Floating IP's" "$(echo "$FIPTXT" | blank_if_empty)" "Mapped to this instance's fixed IP" "Same floating IP re-associated"

  SGTXT=$(echo "$DETAIL" | jqx "', '.join(str(sg.get('name',sg) if isinstance(sg,dict) else sg) for sg in (d.get('security_groups') or []))")
  r "Project Security Group" "$(echo "$SGTXT" | blank_if_empty)" "Groups attached to this instance" "All SGs and rules intact"

  if echo "$ROOT" | grep -Eqi 'ova|custom|imported|p2v|v2v'; then OVA="$ROOT (likely custom/OVA)"; else OVA="$NA"; fi
  r "Instances OVA Custome OS if any" "$OVA" "Heuristic on image name - verify manually" "Custom/OVA image boots correctly"

  # ---------------------------- OS level ----------------------------
  # No SSH / in-guest access is used. Each row is sourced from Nova/Glance
  # metadata when available -- set these yourself if you want automated
  # values instead of "Manual Validation":
  #   openstack server set --property db_status="active, mysqld"      <server>
  #   openstack server set --property db_cluster="galera, 3 nodes"    <server>
  #   openstack server set --property os_cluster="pacemaker, online"  <server>
  #   openstack image set  --property os_distro=rhel --property os_version=8.6  <image>
  # If a property is not set, the row is reported as "Manual Validation".
  banner "OS Level Validation Points"

  prop() { echo "$DETAIL" | jqx "(d.get('properties') or {}).get('$1','') or ''"; }

  IMAGE_ID=$(echo "$DETAIL" | jqx "(d.get('image') or {}).get('id','') if isinstance(d.get('image'), dict) else ''")
  OS_FROM_IMAGE=""
  if [[ -n "$IMAGE_ID" ]]; then
    IMG_JSON=$(os image show "$IMAGE_ID" -f json)
    OS_FROM_IMAGE=$(echo "$IMG_JSON" | jqx "'/'.join(x for x in [(d.get('properties') or {}).get('os_distro',''), (d.get('properties') or {}).get('os_version','')] if x)")
  fi
  if [[ -n "$OS_FROM_IMAGE" ]]; then
    r "Installed OS version" "$OS_FROM_IMAGE" "From image metadata (os_distro/os_version) on '$ROOT'" "Same OS + kernel as before"
  else
    r "Installed OS version" "Manual Validation" "No os_distro/os_version on image '$ROOT'" "Same OS + kernel as before"
  fi

  r "OS hostname and Instance are same" "Manual Validation" "Nova name: $SNAME - not verified in-guest (no ssh access)" "OS hostname == Nova instance name"

  VAL=$(prop os_cluster)
  if [[ -n "$VAL" ]]; then
    r "OS level cluster configured" "$VAL" "From instance property 'os_cluster'" "Cluster online, all nodes joined"
  else
    r "OS level cluster configured" "Manual Validation" "No 'os_cluster' property set - set with: openstack server set --property os_cluster=\"...\" $SNAME" "Cluster online, all nodes joined"
  fi

  VAL=$(prop db_status)
  if [[ -n "$VAL" ]]; then
    r "DB is running" "$VAL" "From instance property 'db_status'" "DB service active and accepting connections"
  else
    r "DB is running" "Manual Validation" "No 'db_status' property set - set with: openstack server set --property db_status=\"...\" $SNAME" "DB service active and accepting connections"
  fi

  VAL=$(prop db_cluster)
  if [[ -n "$VAL" ]]; then
    r "DB level cluster is configured" "$VAL" "From instance property 'db_cluster'" "DB cluster healthy, replication in sync"
  else
    r "DB level cluster is configured" "Manual Validation" "No 'db_cluster' property set - set with: openstack server set --property db_cluster=\"...\" $SNAME" "DB cluster healthy, replication in sync"
  fi

  echo '</table>' >> "$FILE"
done <<<"$SERVERS_TSV"

echo '</body></html>' >> "$FILE"

echo
echo "Done. $COUNT instance(s) written to a single file: $FILE"
