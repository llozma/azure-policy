import base64
import json
import os
import sys
import requests
from copy import deepcopy
from datetime import date
from pathlib import Path
from typing import Any, Dict, List, Optional, Set, Tuple

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

def get_all_policy_files(owner: str, repo: str, branch_info: Dict[str, Any]) -> List[Dict[str, Any]]:
    tree_sha = branch_info["commit"]["commit"]["tree"]["sha"]
    tree = github_get_git_tree_recursive(owner, repo, tree_sha)

    policy_files: List[Dict[str, Any]] = []
    for item in tree.get("tree", []):
        path = item.get("path", "")
        if item.get("type") == "blob" and is_policy_path(path):
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

    return None

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
        policy_files = get_all_policy_files(upstream_owner, upstream_name, branch_info)
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

    baseline["lastProcessedCommit"] = current_head_sha
    save_json(BASELINE_PATH, baseline)
    save_json(STATUS_PATH, status_data)



if __name__ == "__main__":
    sys.exit(main())