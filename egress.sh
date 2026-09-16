get_egress_details() {
    local ns="$1"
    [[ "$CLI" != "oc" ]] && return

    local ns_json_file egressip_json_file out
    ns_json_file=$(mktemp)
    egressip_json_file=$(mktemp)
    trap 'rm -f "$ns_json_file" "$egressip_json_file"' RETURN

    oc get ns "$ns" -o json > "$ns_json_file" 2>/dev/null
    oc get egressip -o json > "$egressip_json_file" 2>/dev/null

    out=$(python3 - "$ns_json_file" "$egressip_json_file" <<'PYEOF'
import json, sys

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

ns_file, egressip_file = sys.argv[1], sys.argv[2]

ns_obj = load(ns_file)
ns_labels = ns_obj.get("metadata", {}).get("labels", {}) or {}

d = load(egressip_file)
found = []
for item in d.get("items", []):
    sel = item.get("spec", {}).get("namespaceSelector", {}) or {}
    match_labels = sel.get("matchLabels", {}) or {}

    # Subset match: every key/value in matchLabels must exist in the
    # namespace's actual labels - works regardless of which label key
    # this cluster/environment actually uses (not hardcoded to "name").
    is_match = len(match_labels) > 0 and all(
        ns_labels.get(k) == v for k, v in match_labels.items()
    )

    # Fallback: evaluate matchExpressions (In / NotIn / Exists / DoesNotExist)
    if not is_match:
        expr_list = sel.get("matchExpressions", []) or []
        if expr_list:
            is_match = True
            for e in expr_list:
                key = e.get("key")
                op = e.get("operator")
                vals = e.get("values", [])
                actual = ns_labels.get(key)
                if op == "In":
                    ok = actual in vals
                elif op == "NotIn":
                    ok = actual not in vals
                elif op == "Exists":
                    ok = key in ns_labels
                elif op == "DoesNotExist":
                    ok = key not in ns_labels
                else:
                    ok = False
                if not ok:
                    is_match = False
                    break

    if is_match:
        ips = item.get("spec", {}).get("egressIPs", [])
        found.append(", ".join(ips))

print(" | ".join(found))
PYEOF
)

    if [[ -n "$out" ]]; then
        echo "$out"
    else
        local netns_egress
        netns_egress=$(oc get netnamespace "$ns" -o jsonpath='{.egressIPs}' 2>/dev/null)
        [[ -n "$netns_egress" && "$netns_egress" != "[]" ]] && echo "$netns_egress"
    fi
}
