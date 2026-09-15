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
PROJ_ID=$(echo "$PROJ_JSON"   | jqx "d.get('id','')")
PROJ_NAME=$(echo "$PROJ_JSON" | jqx "d.get('name','')")
PROJ_DOM=$(echo "$PROJ_JSON"  | jqx "d.get('domain_id') or 'default'")

if [[ -z "$CLUSTER" ]]; then
  AUTH=${OS_AUTH_URL:-}
  [[ -z "$AUTH" && -n "$CLOUD" ]] && AUTH="cloud:$CLOUD"
  CLUSTER=$(sed -E 's#https?://##; s#[:/].*##' <<<"${AUTH:-$NA}")
fi

QUOTA=$(os quota show "$PROJ_ID" -f json)
q() { echo "$QUOTA" | jqx "d.get('$1') if d.get('$1') not in (None,'') else '-'"; }
QUOTA_TXT="vCPU: $(q cores) | RAM(MB): $(q ram) | Instances: $(q instances) | Volumes: $(q volumes) | Gigabytes: $(q gigabytes) | Snapshots: $(q snapshots) | Floating IPs: $(q floating_ips) | Sec-Groups: $(q secgroups) | Networks: $(q networks) | Ports: $(q ports)"

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

declare -a INDEX=()

# ================================ per instance ===============================
while IFS=$'\t' read -r SID SNAME SSTAT SFLAV SHOST SNET; do
  [[ -z "$SID" ]] && continue
  echo "   - $SNAME"
  FSAFE=$(printf '%s' "$SNAME" | tr -c 'A-Za-z0-9._-' '_')
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
done <<<"$SERVERS_TSV"

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
