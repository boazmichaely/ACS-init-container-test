#!/usr/bin/env python3
"""
Thin RHACS Central REST API helper for the init-container EAP test workflow.

Reads ROX_CENTRAL_ENDPOINT and ROX_API_TOKEN from the environment only
(never from argv), so the token never shows up in `ps` output or shell
history. Run via scripts/setup.sh or scripts/test.sh, which source
common.sh to populate those env vars first.
"""
import json
import os
import sys
import ssl
import urllib.request
import urllib.error
import urllib.parse
import argparse


def _endpoint():
    ep = os.environ.get("ROX_CENTRAL_ENDPOINT")
    tok = os.environ.get("ROX_API_TOKEN")
    if not ep or not tok:
        sys.exit("ERROR: ROX_CENTRAL_ENDPOINT / ROX_API_TOKEN not set in environment.")
    return ep, tok


def _request(method, path, body=None, query=None):
    ep, tok = _endpoint()
    url = f"https://{ep}{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {tok}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"error": raw.decode(errors="replace")}


def find_policy_by_name(name):
    status, body = _request("GET", "/v1/policies")
    if status != 200:
        sys.exit(f"ERROR listing policies: {status} {body}")
    for p in body.get("policies", []):
        if p.get("name") == name:
            return p
    return None


def cmd_upsert_policy(args):
    with open(args.file) as f:
        policy = json.load(f)
    existing = find_policy_by_name(policy["name"])
    if existing:
        policy["id"] = existing["id"]
        status, body = _request("PUT", f"/v1/policies/{existing['id']}", policy)
        action = "updated"
    else:
        status, body = _request("POST", "/v1/policies", policy)
        action = "created"
    if status not in (200, 201):
        sys.exit(f"ERROR upserting policy '{policy['name']}': {status} {json.dumps(body)}")
    pid = body.get("id", existing["id"] if existing else None)
    print(f"{action} policy '{policy['name']}' (id={pid})")


def cmd_delete_policy(args):
    existing = find_policy_by_name(args.name)
    if not existing:
        print(f"policy '{args.name}' not found, nothing to delete")
        return
    status, body = _request("DELETE", f"/v1/policies/{existing['id']}")
    if status not in (200, 204):
        sys.exit(f"ERROR deleting policy '{args.name}': {status} {body}")
    print(f"deleted policy '{args.name}' (id={existing['id']})")


def cmd_set_enforcement(args):
    summary = find_policy_by_name(args.name)
    if not summary:
        sys.exit(f"policy '{args.name}' not found")
    # The list endpoint returns an abbreviated policy object; fetch the full
    # definition before mutating and writing it back.
    status, existing = _request("GET", f"/v1/policies/{summary['id']}")
    if status != 200:
        sys.exit(f"ERROR fetching full policy '{args.name}': {status} {existing}")
    # A DEPLOY-stage policy only reaches the admission controller if both of these
    # enforcement actions are set - this mirrors what the Central UI's "Enforce"
    # toggle sends, not the more obviously-named FAIL_DEPLOYMENT_CREATE_ENFORCEMENT.
    existing["enforcementActions"] = (
        ["SCALE_TO_ZERO_ENFORCEMENT", "UNSATISFIABLE_NODE_CONSTRAINT_ENFORCEMENT"] if args.on else []
    )
    status, body = _request("PUT", f"/v1/policies/{existing['id']}", existing)
    if status not in (200, 201):
        sys.exit(f"ERROR updating enforcement on '{args.name}': {status} {json.dumps(body)}")
    print(f"enforcement {'ENABLED' if args.on else 'disabled'} on policy '{args.name}'")


def cmd_violations(args):
    status, body = _request(
        "GET", "/v1/alerts",
        query={"query": f"Namespace:{args.namespace}", "pagination.limit": "200"},
    )
    if status != 200:
        sys.exit(f"ERROR listing alerts: {status} {body}")
    out = []
    for a in body.get("alerts", []):
        out.append({
            "deployment": a.get("deployment", {}).get("name"),
            "policy": a.get("policy", {}).get("name"),
            "state": a.get("state"),
            "id": a.get("id"),
        })
    print(json.dumps(out, indent=2))


def cmd_deployments(args):
    status, body = _request(
        "GET", "/v1/deployments",
        query={"query": f"Namespace:{args.namespace}", "pagination.limit": "200"},
    )
    if status != 200:
        sys.exit(f"ERROR listing deployments: {status} {body}")
    out = []
    for d in body.get("deployments", []):
        out.append({
            "name": d.get("name"),
            "id": d.get("id"),
            "containers": [
                {
                    "name": c.get("name"),
                    "image": (c.get("image") or {}).get("name"),
                }
                for c in d.get("containers", [])
            ],
        })
    print(json.dumps(out, indent=2))


def cmd_image_vulns(args):
    status, body = _request("GET", f"/v1/images", query={"query": f"Image:{args.image}"})
    if status != 200:
        sys.exit(f"ERROR fetching image '{args.image}': {status} {body}")
    imgs = body.get("images", [])
    if not imgs:
        print(json.dumps({"image": args.image, "found": False}))
        return
    img = imgs[0]
    summary = img.get("vulnerabilityCounts") or img.get("scan", {}).get("summary")
    print(json.dumps({"image": args.image, "found": True, "summary": summary}, indent=2))


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("upsert-policy")
    p.add_argument("file")
    p.set_defaults(func=cmd_upsert_policy)

    p = sub.add_parser("delete-policy")
    p.add_argument("name")
    p.set_defaults(func=cmd_delete_policy)

    p = sub.add_parser("set-enforcement")
    p.add_argument("name")
    p.add_argument("--on", action="store_true")
    p.add_argument("--off", dest="on", action="store_false")
    p.set_defaults(func=cmd_set_enforcement)

    p = sub.add_parser("violations")
    p.add_argument("--namespace", required=True)
    p.set_defaults(func=cmd_violations)

    p = sub.add_parser("deployments")
    p.add_argument("--namespace", required=True)
    p.set_defaults(func=cmd_deployments)

    p = sub.add_parser("image-vulns")
    p.add_argument("--image", required=True)
    p.set_defaults(func=cmd_image_vulns)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
