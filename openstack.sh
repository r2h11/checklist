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
#                                             [-s <ssh-user>] [-i <instance>]
#   -p  Project (tenant) name or ID                       (required)
#   -c  Cloud name from clouds.yaml (else source the RC file first)
#   -n  OSP cluster / overcloud name shown in the report  (default: derived)
#   -o  Output directory                                  (default: ./validation)
#   -s  SSH user for OS-level checks                      (default: skip)
#   -i  Limit to one instance (name or ID); repeatable
#
# Requires: python3-openstackclient. JSON parsing uses python3 (no jq needed --
# python3 is already required to run the openstack CLI itself).
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
command -v python3   >/dev/null || { echo "ERROR: python3 not found (required by the openstack CLI itself)." >&2; exit 1; }

OS_OPTS=()
[[ -n "$CLOUD" ]] && OS_OPTS+=(--os-cloud "$CLOUD")
os() { openstack "${OS_OPTS[@]}" "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
# jqx: minimal jq replacement using python3.
#   echo "$JSON" | jqx '<python expression using d = parsed JSON>' [extra args...]
#   Extra args are available inside the expression as a[0], a[1], ...
#   Lists/tuples are printed comma-joined; None prints as empty string.
#
# Implementation note: the python helper is written to a real temp file
# (not a heredoc passed as the process's own stdin) because `python3 -
# <<PYEOF` would consume the heredoc AS the script's stdin, leaving nothing
# for json.load(sys.stdin) to read from the actual piped JSON.
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

QUOTA=$(openstack "${OS_OPTS[@]}" quota show "$PROJ_ID" -f json 2>/dev/null); [[ -z "$QUOTA" ]] && QUOTA='{}'
LIMITS=$(openstack "${OS_OPTS[@]}" limits show --absolute --project "$PROJ_ID" -f json 2>/dev/null); [[ -z "$LIMITS" ]] && LIMITS='[]'

q() {  # q <key> [limits-name]
  local v
  v=$(jq -r --arg k "$1" '.[$k] // .[($k|gsub("_";"-"))] // .[($k|gsub("-";"_"))] // empty' <<<"$QUOTA")
  if [[ -z "$v" && -n "${2:-}" ]]; then
    v=$(jq -r --arg n "$2" '[.[]|select(.Name==$n)|.Value][0] // empty' <<<"$LIMITS")
  fi
  echo "${v:--}"
}

QUOTA_TXT="vCPU: $(q cores maxTotalCores) | RAM(MB): $(q ram maxTotalRAMSize) | Instances: $(q instances maxTotalInstances) | Volumes: $(q volumes) | Gigabytes: $(q gigabytes) | Snapshots: $(q snapshots) | Floating IPs: $(q floating_ips maxTotalFloatingIps) | Sec-Groups: $(q secgroups maxSecurityGroups) | Networks: $(q networks) | Ports: $(q ports)"

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

os_check() { [[ -z "$SSH_USER" || -z "${1:-}" ]] && { echo ""; return; }
  timeout 15 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=8 \
      "${SSH_USER}@${1}" "$2" 2>/dev/null | tr '\n' ' '; }

# ----------------------------------------------------------- file header -----
{
  echo "<html><head><meta charset='utf-8'><title>Validation - $(esc "$PROJ_NAME")</title><style>$CSS</style></head><body>"
  echo "<a id='top'></a><h2>OpenStack Validation Checklist &ndash; $(esc "$PROJ_NAME")</h2>"
  echo "<p class='meta'>Cluster: $(esc "$CLUSTER") &nbsp;|&nbsp; $PROJ_COUNT &nbsp;|&nbsp; Generated: $STAMP</p>"
} > "$FILE"

# ------------------------------------------------- summary/index table -------
# Cheap first pass (no per-instance API calls) so the index can sit at the
# very top of the file, above every instance's detailed section below it.
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
  r "Project Quota details" "$QUOTA_TXT" "openstack quota show" "Quota sufficient for all workloads"
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

  MIG=$(os server migration list --server "$SID" -f json); [[ -z "$MIG" ]] && MIG='[]'
  L=$(echo "$MIG" | jqx "len([x for x in d if str(x.get('Type','')).lower()=='live-migration'])")
  C=$(echo "$MIG" | jqx "len([x for x in d if 'resize' in str(x.get('Type','')).lower() or str(x.get('Type','')).lower()=='migration'])")
  LAST=$(echo "$MIG" | jqx "(sorted(d, key=lambda x: x.get('Updated At','') or '')[-1].get('Updated At','-')) if d else '-'")
  r "Live Migrations of Instances" "${L:-0}" "Last migration event: $LAST" "Live migration completes, no downtime"
  r "Cold Migrations of Instances" "${C:-0}" "Resize / cold migration count" "Cold migration completes, instance ACTIVE"

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
  # Sourced primarily from Nova instance properties/tags (no SSH needed).
  # Convention this script looks for -- set these on the instance yourself:
  #   openstack server set --property db_status="active, mysqld"      <server>
  #   openstack server set --property db_cluster="galera, 3 nodes"    <server>
  #   openstack server set --property os_cluster="pacemaker, online"  <server>
  #   openstack image set  --property os_distro=rhel --property os_version=8.6  <image>
  # If a property is missing AND -s <ssh-user> was given, the script falls
  # back to a live SSH check for that one row. If neither is available, the
  # row is left "Not Available" rather than guessed.
  banner "OS Level Validation Points"

  prop() { echo "$DETAIL" | jqx "(d.get('properties') or {}).get('$1','') or ''"; }

  # -- Installed OS version: prefer Glance image properties (os_distro/os_version) --
  IMAGE_ID=$(echo "$DETAIL" | jqx "(d.get('image') or {}).get('id','') if isinstance(d.get('image'), dict) else ''")
  OS_FROM_IMAGE=""
  if [[ -n "$IMAGE_ID" ]]; then
    IMG_JSON=$(os image show "$IMAGE_ID" -f json)
    OS_FROM_IMAGE=$(echo "$IMG_JSON" | jqx "'/'.join(x for x in [(d.get('properties') or {}).get('os_distro',''), (d.get('properties') or {}).get('os_version','')] if x)")
  fi
  if [[ -n "$OS_FROM_IMAGE" ]]; then
    r "Installed OS version" "$OS_FROM_IMAGE" "From image metadata (os_distro/os_version) on '$ROOT'" "Same OS + kernel as before"
  else
    OSV=$(os_check "$IP" ". /etc/os-release 2>/dev/null; echo \$PRETTY_NAME \$(uname -r)")
    if [[ -n "$OSV" ]]; then
      r "Installed OS version" "$OSV" "${SSH_USER:+via ssh $IP (image had no os_distro/os_version property)}" "Same OS + kernel as before"
    else
      r "Installed OS version" "$NA" "No os_distro/os_version on image '$ROOT'${SSH_USER:+, and ssh check found nothing}" "Same OS + kernel as before"
    fi
  fi

  # -- OS hostname: from Nova only, no in-guest verification unless -s given --
  if [[ -n "$SSH_USER" ]]; then
    OSH=$(os_check "$IP" "hostname -f")
    if [[ -n "$OSH" ]]; then
      if [[ "${OSH%% *}" == "$SNAME"* ]]; then M="MATCH"; else M="MISMATCH"; fi
      r "OS hostname and Instance are same" "$OSH - $M" "Nova name: $SNAME (verified via ssh)" "OS hostname == Nova instance name"
    else
      r "OS hostname and Instance are same" "$NA" "Nova name: $SNAME (ssh check failed)" "OS hostname == Nova instance name"
    fi
  else
    r "OS hostname and Instance are same" "$SNAME" "From Nova instance name only - not verified in-guest" "OS hostname == Nova instance name"
  fi

  # -- OS level cluster --
  VAL=$(prop os_cluster)
  if [[ -n "$VAL" ]]; then
    r "OS level cluster configured" "$VAL" "From instance property 'os_cluster'" "Cluster online, all nodes joined"
  else
    VAL=$(os_check "$IP" "pcs status 2>/dev/null | head -3 || crm status 2>/dev/null | head -3 || systemctl is-active pacemaker corosync 2>/dev/null")
    if [[ -n "$SSH_USER" ]]; then
      r "OS level cluster configured" "$(echo "$VAL" | blank_if_empty)" "No 'os_cluster' property set; checked via ssh" "Cluster online, all nodes joined"
    else
      r "OS level cluster configured" "$NA" "No 'os_cluster' property set on instance - set with: openstack server set --property os_cluster=\"...\" $SNAME" "Cluster online, all nodes joined"
    fi
  fi

  # -- DB running --
  VAL=$(prop db_status)
  if [[ -n "$VAL" ]]; then
    r "DB is running" "$VAL" "From instance property 'db_status'" "DB service active and accepting connections"
  else
    VAL=$(os_check "$IP" "systemctl is-active mysqld mariadb postgresql 2>/dev/null | paste -sd, -; ps -ef | grep -Ec '[m]ysqld|[p]ostgres|[o]ra_pmon'")
    if [[ -n "$SSH_USER" ]]; then
      r "DB is running" "$(echo "$VAL" | blank_if_empty)" "No 'db_status' property set; checked via ssh" "DB service active and accepting connections"
    else
      r "DB is running" "$NA" "No 'db_status' property set on instance - set with: openstack server set --property db_status=\"...\" $SNAME" "DB service active and accepting connections"
    fi
  fi

  # -- DB level cluster --
  VAL=$(prop db_cluster)
  if [[ -n "$VAL" ]]; then
    r "DB level cluster is configured" "$VAL" "From instance property 'db_cluster'" "DB cluster healthy, replication in sync"
  else
    VAL=$(os_check "$IP" "pcs resource show 2>/dev/null | grep -Ei 'sql|db|galera' | head -3; systemctl is-active garbd galera 2>/dev/null")
    if [[ -n "$SSH_USER" ]]; then
      r "DB level cluster is configured" "$(echo "$VAL" | blank_if_empty)" "No 'db_cluster' property set; checked via ssh" "DB cluster healthy, replication in sync"
    else
      r "DB level cluster is configured" "$NA" "No 'db_cluster' property set on instance - set with: openstack server set --property db_cluster=\"...\" $SNAME" "DB cluster healthy, replication in sync"
    fi
  fi

  echo '</table>' >> "$FILE"
done <<<"$SERVERS_TSV"

echo '</body></html>' >> "$FILE"

echo
echo "Done. $COUNT instance(s) written to a single file: $FILE"
[[ -z "$SSH_USER" ]] && echo "  Note: OS-level rows left as '$NA' (no -s <ssh-user> given)."
