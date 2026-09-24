#!/usr/bin/env bash
# make_compliance_matrix.sh
# Builds a single self-contained HTML table in the "Security Reqs ID / UCF
# Domain / UCF Control / Requirement Detail / Guidelines / Compliance Status /
# Expected Evidence / Evidence Attachments / Project Team / Remarks" format,
# with real evidence files (screenshots, Outlook .msg/.eml, PDFs, docs)
# embedded or attached in the Evidence Attachments column.
#
# Usage:
#   ./make_compliance_matrix.sh --init                    # create sample rows.tsv
#   ./make_compliance_matrix.sh [rows.tsv] [out.html]
#
# Optional env vars: TITLE, ORG, PREPARED_BY

set -euo pipefail

TITLE="${TITLE:-Security Requirements Compliance Matrix}"
ORG="${ORG:-}"
PREPARED_BY="${PREPARED_BY:-$(whoami)}"

# ---------- --init: sample data file ----------
# Columns are TAB-separated (safer than | or , since text fields contain both):
# ReqID<TAB>Domain<TAB>Control<TAB>RequirementDetail<TAB>Guidelines<TAB>Status<TAB>ExpectedEvidence<TAB>EvidenceFiles<TAB>ProjectTeam<TAB>Remarks
# EvidenceFiles: comma-separated list of file paths (images embed inline, other files become download links)
# Use \n inside a field for a line break (rendered as <br>)
if [[ "${1:-}" == "--init" ]]; then
  mkdir -p evidence
  printf 'ReqID\tDomain\tControl\tRequirementDetail\tGuidelines\tStatus\tExpectedEvidence\tEvidenceFiles\tProjectTeam\tRemarks\n' > rows.tsv
  printf 'SEC-01\tNetwork Security\t38\t"Establish and maintain a secure network architecture. A secure network architecture must address segmentation, least privilege, and availability, at a minimum"\\nThe solution shall follow functional segregation principles and solution shall have n-tiers\tGuidelines:\\n1. Fill the design template based in the proposed infra\tCompliant\tExpected Evidence:\\n1. Approved DCR form\tevidence/dcr_form.png\tNetwork Team\t\n' >> rows.tsv
  printf 'SEC-10\tNetwork Security\t20\tEndpoint Security Requiremnts\tObtain Compatbility confirmation\tCompliant\tExpected Evidence:\\n1. Email confirmation\tevidence/email_confirmation.eml\tEndpoint Team\t\n' >> rows.tsv
  echo "Created rows.tsv and evidence/ folder. Edit them (TAB-separated), then run:"
  echo "  ./make_compliance_matrix.sh rows.tsv matrix.html"
  exit 0
fi

ROWS_FILE="${1:-rows.tsv}"
OUTPUT="${2:-compliance_matrix.html}"

[[ -f "$ROWS_FILE" ]] || { echo "Rows file '$ROWS_FILE' not found. Run with --init first." >&2; exit 1; }

# ---------- helpers ----------
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }
# turn literal \n into <br> after escaping
nl2br() { esc "$1" | sed 's/\\n/<br>/g'; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
b64() { base64 < "$1" | tr -d '\n'; }
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

mime_for() {
  case "$(lower "${1##*.}")" in
    png)  echo "image/png" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    gif)  echo "image/gif" ;;
    webp) echo "image/webp" ;;
    eml)  echo "message/rfc822" ;;
    msg)  echo "application/vnd.ms-outlook" ;;
    pdf)  echo "application/pdf" ;;
    doc)  echo "application/msword" ;;
    docx) echo "application/vnd.openxmlformats-officedocument.wordprocessingml.document" ;;
    xls)  echo "application/vnd.ms-excel" ;;
    xlsx) echo "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ;;
    *)    echo "application/octet-stream" ;;
  esac
}

is_image() {
  case "$(lower "${1##*.}")" in
    png|jpg|jpeg|gif|webp) return 0 ;;
    *) return 1 ;;
  esac
}

status_class() {
  case "$(lower "$1")" in
    compliant)      echo "ok" ;;
    non-compliant)  echo "bad" ;;
    "in progress")  echo "warn" ;;
    partial*)       echo "warn" ;;
    *)              echo "na" ;;
  esac
}

# render the Evidence Attachments cell for a comma-separated file list
render_evidence_cell() {
  local files="$1" f base
  IFS=',' read -ra arr <<< "$files"
  for f in "${arr[@]}"; do
    f="$(trim "$f")"
    [[ -z "$f" ]] && continue
    base="$(basename "$f")"
    if [[ ! -f "$f" ]]; then
      printf '<div class="missing">Missing: %s</div>' "$(esc "$f")"
      echo "WARNING: evidence file not found: $f" >&2
      continue
    fi
    if is_image "$f"; then
      printf '<a class="thumb-link" href="data:%s;base64,%s" download="%s"><img class="thumb" alt="%s" src="data:%s;base64,%s"></a>' \
        "$(mime_for "$f")" "$(b64 "$f")" "$(esc "$base")" "$(esc "$base")" "$(mime_for "$f")" "$(b64 "$f")"
    else
      printf '<a class="attach" download="%s" href="data:%s;base64,%s">&#128206; %s</a>' \
        "$(esc "$base")" "$(mime_for "$f")" "$(b64 "$f")" "$(esc "$base")"
    fi
  done
}

# ---------- build HTML ----------
TMP="$(mktemp)"
{
cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(esc "$TITLE")</title>
<style>
  * { box-sizing: border-box; }
  body { margin:0; font-family: -apple-system, "Segoe UI", Roboto, Arial, sans-serif;
         background:#f5f6f8; color:#1d2433; }
  .wrap { max-width: 1400px; margin: 0 auto; padding: 28px 20px 60px; }
  h1 { margin:0 0 4px; font-size:22px; }
  .meta { color:#667085; font-size:13px; margin-bottom:18px; }
  .tbl-wrap { overflow-x:auto; border:1px solid #d0d5dd; border-radius:6px; background:#fff; }
  table { border-collapse: collapse; width:100%; min-width:1300px; font-size:13px; }
  thead th { background:#0f6cbd; color:#fff; text-align:left; padding:10px 10px;
             border:1px solid #0a5a9c; position:sticky; top:0; }
  tbody td { border:1px solid #d0d5dd; padding:10px 10px; vertical-align:top; }
  tbody tr:nth-child(even) { background:#fafbfc; }
  td.id, td.control { white-space:nowrap; font-weight:600; }
  td.status { white-space:nowrap; }
  .badge { display:inline-block; font-size:12px; font-weight:600; padding:3px 9px; border-radius:999px; }
  .ok   { background:#ecfdf3; color:#067647; }
  .bad  { background:#fef3f2; color:#b42318; }
  .warn { background:#fffaeb; color:#b54708; }
  .na   { background:#f2f4f7; color:#475467; }
  .evidence-col { min-width:150px; }
  .thumb-link { display:inline-block; margin:2px; }
  .thumb { width:70px; height:70px; object-fit:cover; border:1px solid #d0d5dd; border-radius:4px; }
  .attach { display:inline-flex; align-items:center; gap:6px; padding:5px 8px; margin:2px 0;
            border:1px solid #d0d5dd; border-radius:6px; text-decoration:none; color:#1d2433;
            background:#fafbfc; font-size:12px; }
  .attach:hover { background:#eef1f4; }
  .missing { color:#b42318; font-size:12px; }
  footer { color:#667085; font-size:12px; margin-top:20px; text-align:center; }
</style>
</head>
<body>
<div class="wrap">
  <h1>$(esc "$TITLE")</h1>
  <div class="meta">$( [[ -n "$ORG" ]] && printf '%s &middot; ' "$(esc "$ORG")" )Prepared by $(esc "$PREPARED_BY") &middot; $(date '+%d %b %Y, %H:%M')</div>
  <div class="tbl-wrap">
  <table>
    <thead>
      <tr>
        <th>Security Reqs ID</th>
        <th>UCF Domain</th>
        <th>UCF Control</th>
        <th>Requirement Detail</th>
        <th>Guidelines/Templates/SPOCs</th>
        <th>Compliance Status</th>
        <th>Expected Evidence</th>
        <th class="evidence-col">Evidence Attachments</th>
        <th>Project Team</th>
        <th>Remarks</th>
      </tr>
    </thead>
    <tbody>
EOF

first=1
while IFS=$'\t' read -r reqid domain control detail guide status evidtxt evidfiles team remarks; do
  if [[ $first -eq 1 ]]; then first=0; continue; fi   # skip header row
  reqid="$(trim "${reqid:-}")"
  [[ -z "$reqid" ]] && continue
  domain="$(trim "${domain:-}")"; control="$(trim "${control:-}")"
  detail="${detail:-}"; guide="${guide:-}"; status="$(trim "${status:-}")"
  evidtxt="${evidtxt:-}"; evidfiles="$(trim "${evidfiles:-}")"
  team="$(trim "${team:-}")"; remarks="${remarks:-}"

  cat <<ROW
      <tr>
        <td class="id">$(esc "$reqid")</td>
        <td>$(esc "$domain")</td>
        <td class="control">$(esc "$control")</td>
        <td>$(nl2br "$detail")</td>
        <td>$(nl2br "$guide")</td>
        <td class="status"><span class="badge $(status_class "$status")">$(esc "${status:-N/A}")</span></td>
        <td>$(nl2br "$evidtxt")</td>
        <td class="evidence-col">$(render_evidence_cell "$evidfiles")</td>
        <td>$(esc "$team")</td>
        <td>$(nl2br "$remarks")</td>
      </tr>
ROW
done < "$ROWS_FILE"

cat <<EOF
    </tbody>
  </table>
  </div>
  <footer>Generated by make_compliance_matrix.sh &middot; evidence files are embedded/attached in this file</footer>
</div>
</body>
</html>
EOF
} > "$TMP"

mv "$TMP" "$OUTPUT"
echo "Matrix created: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
