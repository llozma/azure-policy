import base64
import json
import os
import sys
import requests
from copy import deepcopy
from datetime import date
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

CONFIG = None
BASELINE_PATH = Path("config/baseline.json")
SCOPE_PATH = Path("config/scope.json")
STATUS_PATH = Path("config/policy_status.json")
INITIATIVE_PATH = Path("policy-set/storage-initiative.json")
REPORT_PATH = Path("reports/latest-report.md")
GITHUB_API = "https://api.github.com"
SESSION = requests.Session()

TOKEN = os.environ.get("GITHUB_TOKEN")

if TOKEN:
    SESSION.headers.update(
        {
            "Authorization": f"Bearer {TOKEN}",
            "Accept": "application/vnd.github+json",
        }
    )

def load_json(path: Path, default: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    if not path.exists():
        return default or {}

    with path.open("r", encoding="utf-8") as f:
        content = f.read().strip()

    if not content:
        return default or {}

    return json.loads(content)

def save_json(path: Path, data: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")

def github_get(url: str) -> Dict[str, Any]:
    response = SESSION.get(url, timeout=30)
    response.raise_for_status()
    return response.json()

def github_get_repo(owner: str, repo: str) -> Dict[str, Any]:
    return github_get(f"{GITHUB_API}/repos/{owner}/{repo}")

def github_get_branch(owner: str, repo: str, branch: str) -> Dict[str, Any]:
    return github_get(f"{GITHUB_API}/repos/{owner}/{repo}/branches/{branch}")

def ensure_status_file_shape(status_data: Dict[str, Any]) -> Dict[str, Any]:
    data = deepcopy(status_data) if status_data else {}
    if "policies" not in data or not isinstance(data["policies"], dict):
        data["policies"] = {}
    return data

def github_compare(owner: str, repo: str, base: str, head: str) -> Dict[str, Any]:
    return github_get(f"{GITHUB_API}/repos/{owner}/{repo}/compare/{base}...{head}")

def github_get_git_tree_recursive(owner: str, repo: str, tree_sha: str) -> Dict[str, Any]:
    return github_get(f"{GITHUB_API}/repos/{owner}/{repo}/git/trees/{tree_sha}?recursive=1")

def get_all_policy_files(owner: str, repo: str, branch_info: Dict[str, Any], scope: Dict[str, Any]) -> List[Dict[str, Any]]:
    tree_sha = branch_info["commit"]["commit"]["tree"]["sha"]
    tree = github_get_git_tree_recursive(owner, repo, tree_sha)

    policy_files: List[Dict[str, Any]] = []
    for item in tree.get("tree", []):
        path = item.get("path", "")
        if item.get("type") != "blob":
            continue
        if not is_policy_path(path):
            continue
        if not path_matches_scope(path, scope):
            continue

        policy_files.append(
            {
                "filename": path,
                "status": "full_scan",
            }
        )

    return policy_files

def is_policy_path(path: str) -> bool:
    path_lower = path.lower()
    return (
        path_lower.endswith(".json")
        and "built-in-policies" in path_lower
    )

def get_existing_policy_ids(initiative: Dict[str, Any]) -> Set[str]:
    refs = initiative.get("memberDefinitions", {})
    result = set()

    for item in refs:
        policy_id = item.get("id")
        if isinstance(policy_id, str):
            result.add(policy_id.lower())

    return result

def github_get_file_content(owner: str, repo: str, path: str, ref: str) -> Optional[Dict[str, Any]]:
    raw_url = f"https://raw.githubusercontent.com/{owner}/{repo}/{ref}/{path}"
    raw_response = SESSION.get(raw_url, timeout=30)

    if raw_response.status_code == 200:
        return raw_response.json()

    url = f"{GITHUB_API}/repos/{owner}/{repo}/contents/{path}?ref={ref}"
    response = SESSION.get(url, timeout=30)

    if response.status_code == 404:
        return None

    response.raise_for_status()
    payload = response.json()

    if payload.get("encoding") == "base64" and payload.get("content"):
        content = base64.b64decode(payload["content"]).decode("utf-8")
        return json.loads(content)

    download_url = payload.get("download_url")
    if download_url:
        raw = SESSION.get(download_url, timeout=30)
        raw.raise_for_status()
        return raw.json()


def parse_doc(doc: Dict[str, Any], path: str) -> Dict[str, Any]:
    props = doc.get("properties", {})
    metadata = props.get("metadata", {})

    category = metadata.get("category", "Unknown")
    version = metadata.get("version", "unknown")
    display_name = props.get("displayName", doc.get("name", path))
    policy_type = props.get("policyType", "Unknown")
    mode = props.get("mode", "")
    definition_type = "initiative" if "policyDefinitions" in props else "policy"
    policy_rule = props.get("policyRule", {})
    effects = sorted(extract_effects(policy_rule)) if definition_type == "policy" else []
    resource_providers = sorted(extract_resource_providers(policy_rule)) if definition_type == "policy" else []
    policy_refs = props.get("policyDefinitions", []) if definition_type == "initiative" else []

    return {
        "id": normalize_policy_id(doc),
        "name": doc.get("name"),
        "displayName": display_name,
        "category": category,
        "version": version,
        "policyType": policy_type,
        "mode": mode,
        "definitionType": definition_type,
        "effects": effects,
        "resourceProviders": resource_providers,
        "policyReferenceCount": len(policy_refs),
        "path": path,
        "deprecated": is_deprecated(doc),
    }

def normalize_policy_id(doc: Dict[str, Any]) -> Optional[str]:
    policy_id = doc.get("id")
    if isinstance(policy_id, str):
        return policy_id.lower()
    name = doc.get("name")
    if isinstance(name, str):
        return f"/providers/microsoft.authorization/policydefinitions/{name}".lower()
    return None

def extract_effects(policy_rule: Any) -> Set[str]:
    effects: Set[str] = set()

    def recurse(node: Any) -> None:
        if isinstance(node, dict):
            if "effect" in node and isinstance(node["effect"], str):
                effects.add(node["effect"])
            for value in node.values():
                recurse(value)
        elif isinstance(node, list):
            for item in node:
                recurse(item)

    recurse(policy_rule)
    return effects

def extract_resource_providers(policy_rule: Any) -> Set[str]:
    providers: Set[str] = set()

    def recurse(node: Any) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                if key.lower() in {"field", "source"} and isinstance(value, str):
                    if value.startswith("type"):
                        continue
                    if "/" in value and value.startswith("Microsoft."):
                        providers.add(value.split("/")[0])
                recurse(value)
        elif isinstance(node, list):
            for item in node:
                recurse(item)

    recurse(policy_rule)
    return providers

def is_deprecated(doc: Dict[str, Any]) -> bool:
    metadata = doc.get("properties", {}).get("metadata", {})
    deprecated = metadata.get("deprecated", False)
    return bool(deprecated)

def is_relevant(info: Dict[str, Any], scope: Dict[str, Any]) -> Tuple[bool, List[str]]:
    reasons: List[str] = []

    if info["policyType"] != "BuiltIn":
        return False, reasons

    if scope.get("excludeDeprecated", True) and info["deprecated"]:
        return False, reasons

    categories = set(scope.get("categories", []))
    allowed_effects = set(scope.get("allowedEffects", []))

    if info["category"] in categories:
        reasons.append(f"Kategorie passt: {info['category']}")

    matched_effects = sorted(set(info.get("effects", [])) & allowed_effects)
    if matched_effects:
        reasons.append(f"Effekt passt: {', '.join(matched_effects)}")

    if info["definitionType"] == "initiative" and info["category"] in categories:
        reasons.append("Initiative in relevanter Kategorie")

    return len(reasons) > 0, reasons


def classify_file_change(file_entry: Dict[str, Any]) -> str:
    status = file_entry.get("status", "")
    previous_filename = file_entry.get("previous_filename")
    if status == "added":
        return "neu"
    if status == "modified":
        return "geändert"
    if status == "renamed" and previous_filename:
        return f"umbenannt (früher: {previous_filename})"
    if status == "removed":
        return "entfernt"
    return status or "unbekannt"

def build_report(
    upstream_repo: str,
    base_ref: str,
    head_sha: str,
    results: Dict[str, List[Dict[str, Any]]],
) -> str:
    def add_section(lines: List[str], title: str, items: List[Dict[str, Any]]) -> None:
        lines.append(f"## {title}")
        lines.append("")
        if not items:
            lines.append("Keine Einträge.")
            lines.append("")
            return

        for item in sorted(items, key=lambda x: x["displayName"].lower()):
            lines.append(f"### {item['displayName']}")
            lines.append(f"- Policy ID: `{item['id']}`")
            lines.append(f"- Typ: {item['definitionType']}")
            lines.append(f"- Änderung im Upstream: {item['changeType']}")
            lines.append(f"- Kategorie: {item['category']}")
            lines.append(f"- Version: {item['version']}")
            lines.append(f"- Status: {item['outcome']}")
            lines.append(f"- Pfad: `{item['path']}`")
            if item.get("effects"):
                lines.append(f"- Effekte: {', '.join(item['effects'])}")
            if item.get("resourceProviders"):
                lines.append(f"- Resource Provider: {', '.join(item['resourceProviders'])}")
            if item.get("relevanceReasons"):
                lines.append(f"- Relevanz: {'; '.join(item['relevanceReasons'])}")
            if item.get("statusExplanation"):
                lines.append(f"- Entscheidungslogik: {item['statusExplanation']}")
            if item.get("statusReason"):
                lines.append(f"- Begründung: {item['statusReason']}")
            lines.append("")

    lines: List[str] = []
    lines.append("# Azure Policy Delta Report")
    lines.append("")
    lines.append(f"- Upstream-Repo: `{upstream_repo}`")
    lines.append(f"- Verglichen: `{base_ref}` ... `{head_sha}`")
    lines.append("")

    add_section(lines, "Neu erkannte Kandidaten", results["new_candidate"])
    add_section(lines, "Bereits bekannte Kandidaten", results["known_candidate"])
    add_section(lines, "Geändert seit letzter Entscheidung", results["changed_since_decision"])
    add_section(lines, "Bereits verworfen", results["rejected"])
    add_section(lines, "Zurückgestellt", results["deferred"])
    add_section(lines, "Bereits übernommen oder in Initiative enthalten", results["in_initiative"])
    add_section(lines, "Nicht relevant oder gefiltert", results["ignored"])

    return "\n".join(lines)

def set_status_entry(status_data: Dict[str, Any], policy_id: str, entry: Dict[str, Any]) -> None:
    status_data["policies"][policy_id.lower()] = entry

def get_status_entry(status_data: Dict[str, Any], policy_id: str) -> Optional[Dict[str, Any]]:
    return status_data.get("policies", {}).get(policy_id.lower())

def today_iso() -> str:
    return date.today().isoformat()

def build_status_entry_from_candidate(info: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "status": "candidate",
        "firstSeenDate": today_iso(),
        "lastSeenDate": today_iso(),
        "lastSeenVersion": info["version"],
        "displayName": info["displayName"],
        "category": info["category"],
        "path": info["path"],
    }

def update_seen_metadata(existing_entry: Dict[str, Any], info: Dict[str, Any]) -> Dict[str, Any]:
    updated = deepcopy(existing_entry)
    updated["lastSeenDate"] = today_iso()
    updated["lastSeenVersion"] = info["version"]
    updated["displayName"] = info["displayName"]
    updated["category"] = info["category"]
    updated["path"] = info["path"]
    return updated

def determine_outcome(
    info: Dict[str, Any],
    existing_policy_ids: Set[str],
    status_data: Dict[str, Any],
) -> Tuple[str, Optional[Dict[str, Any]], Optional[str]]:
    """
    outcome:
      - in_initiative
      - new_candidate
      - known_candidate
      - rejected
      - deferred
      - accepted
      - changed_since_decision
      - unknown
    status_entry_to_write
    explanation
    """
    policy_id = info["id"]
    if not policy_id:
        return "unknown", None, "Keine normalisierte Policy-ID verfügbar"

    if policy_id in existing_policy_ids:
        existing_entry = get_status_entry(status_data, policy_id) or {}
        new_entry = update_seen_metadata(existing_entry, info)
        if new_entry.get("status") != "accepted":
            new_entry["status"] = "accepted"
            new_entry["decisionDate"] = new_entry.get("decisionDate", today_iso())
            new_entry["reason"] = new_entry.get("reason", "In Initiative enthalten")
            new_entry["lastReviewedVersion"] = info["version"]
        return "in_initiative", new_entry, "Bereits in Initiative enthalten"

    status_entry = get_status_entry(status_data, policy_id)

    if not status_entry:
        new_entry = build_status_entry_from_candidate(info)
        return "new_candidate", new_entry, "Neu erkannt und noch nicht entschieden"

    updated_entry = update_seen_metadata(status_entry, info)
    current_status = updated_entry.get("status", "candidate")
    reviewed_version = str(updated_entry.get("lastReviewedVersion", "")).strip()

    if current_status in {"rejected", "deferred", "accepted"}:
        if reviewed_version and reviewed_version != info["version"]:
            updated_entry["status"] = "changed_since_decision"
            updated_entry["changedSinceDecisionDate"] = today_iso()
            return (
                "changed_since_decision",
                updated_entry,
                f"Version geändert seit letzter Entscheidung ({reviewed_version} -> {info['version']})",
            )
        return current_status, updated_entry, f"Bereits entschieden: {current_status}"

    if current_status == "changed_since_decision":
        return "changed_since_decision", updated_entry, "Bereits als geändert seit Entscheidung markiert"

    return "known_candidate", updated_entry, "Bereits als Kandidat bekannt"

def path_matches_scope(path: str, scope: Dict[str, Any]) -> bool:
    path_lower = path.lower()
    categories = [c.lower() for c in scope.get("categories", [])]

    return any(category in path_lower for category in categories)

def main(): 
  
    baseline = load_json(BASELINE_PATH)
    scope = load_json(SCOPE_PATH)
    status_data = ensure_status_file_shape(load_json(STATUS_PATH, default={"policies": {}}))
    initiative = load_json(INITIATIVE_PATH)

    results: Dict[str, List[Dict[str, Any]]] = {
        "new_candidate": [],
        "known_candidate": [],
        "changed_since_decision": [],
        "rejected": [],
        "deferred": [],
        "accepted": [],
        "in_initiative": [],
        "ignored": [],
    }

    upstream_repo = baseline["upstreamRepo"]
    upstream_owner, upstream_name = upstream_repo.split("/")

    repo_info = github_get_repo(upstream_owner, upstream_name)
    default_branch = repo_info["default_branch"]

    branch_info = github_get_branch(upstream_owner, upstream_name, default_branch)
    current_head_sha = branch_info["commit"]["sha"]

    base_ref = str(baseline.get("lastProcessedCommit", "")).strip()

    if not base_ref:
        policy_files = get_all_policy_files(upstream_owner, upstream_name, branch_info, scope)
        compare_label = "FULL_SCAN"
    else:
        compare = github_compare(upstream_owner, upstream_name, base_ref, current_head_sha)
        changed_files = compare.get("files", [])
        policy_files = [f for f in changed_files if is_policy_path(f.get("filename", ""))]
        compare_label = base_ref

    existing_policy_ids = get_existing_policy_ids(initiative)

    for file_entry in policy_files:
        if file_entry.get("status") == "removed":
            continue

        filename = file_entry["filename"]
        doc = github_get_file_content(upstream_owner, upstream_name, filename, current_head_sha)
        if not doc:
            continue

        info = parse_doc(doc, filename)
        info["changeType"] = classify_file_change(file_entry)

        relevant, relevance_reasons = is_relevant(info, scope)
        info["relevanceReasons"] = relevance_reasons

        if not relevant:
            info["outcome"] = "ignored"
            results["ignored"].append(info)
            continue

        outcome, status_entry_to_write, explanation = determine_outcome(info, existing_policy_ids, status_data)
        info["outcome"] = outcome
        info["statusExplanation"] = explanation

        if status_entry_to_write and info["id"]:
            set_status_entry(status_data, info["id"], status_entry_to_write)
            if status_entry_to_write.get("reason"):
                info["statusReason"] = status_entry_to_write["reason"]

        if outcome == "new_candidate":
            results["new_candidate"].append(info)
        elif outcome == "known_candidate":
            results["known_candidate"].append(info)
        elif outcome == "changed_since_decision":
            results["changed_since_decision"].append(info)
        elif outcome == "rejected":
            results["rejected"].append(info)
        elif outcome == "deferred":
            results["deferred"].append(info)
        elif outcome in {"accepted", "in_initiative"}:
            results["in_initiative"].append(info)
        else:
            results["ignored"].append(info)

    report = build_report(
        upstream_repo=upstream_repo,
        base_ref=compare_label,
        head_sha=current_head_sha,
        results=results,
    )

    REPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(report, encoding="utf-8")

    baseline["lastProcessedCommit"] = current_head_sha
    save_json(BASELINE_PATH, baseline)
    save_json(STATUS_PATH, status_data)

    print(report)
    return 0




if __name__ == "__main__":
    sys.exit(main())