#!/usr/bin/env python3
"""Resolve explicitly recorded synthetic Sentry events without deleting evidence.

The private JSON manifest records environment (verification or development),
release, and event_ids from a completed verification run. Only include confirmed
synthetic events. Real failures encountered during verification remain actionable.
Native events are never eligible. A group shared with any unlisted event is also
ineligible because Sentry resolves whole issues, not individual events.

Example manifest: {"environment": "verification", "release": "xmplus@1.2.1+14",
                   "event_ids": ["<32-character Sentry event ID>"]}

Use SENTRY_AUTH_TOKEN from the process environment. Preview is the default;
--apply rechecks eligible groups before resolving them. No events are deleted.
Keep manifests and reports outside Git, for example under Temp/.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener


class VerificationError(Exception):
    pass


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Authentication must not follow an API redirect to another origin.
        raise VerificationError("Sentry redirected the request; check --url.")


class SentryApi:
    def __init__(self, url: str, token: str):
        parsed = urlsplit(url)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.path not in ("", "/")
            or parsed.query
            or parsed.fragment
        ):
            raise VerificationError("--url must be an HTTPS origin.")
        self.origin = url.rstrip("/")
        self.token = token
        self.opener = build_opener(NoRedirects())

    def request(self, path: str, *, query=None, body=None):
        url = f"{self.origin}/api/0/{path}"
        if query:
            url += "?" + urlencode(query)
        request = Request(
            url,
            data=None if body is None else json.dumps(body).encode("utf-8"),
            headers={
                "Authorization": f"Bearer {self.token}",
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
            method="GET" if body is None else "PUT",
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                payload = response.read(4 * 1024 * 1024 + 1)
                if len(payload) > 4 * 1024 * 1024:
                    raise VerificationError("Sentry response exceeded 4 MiB.")
                return json.loads(payload), response.headers
        except HTTPError as error:
            # Response bodies can contain account details; do not print them.
            raise VerificationError(f"Sentry returned HTTP {error.code}.") from None
        except (URLError, TimeoutError, OSError):
            raise VerificationError("Sentry request failed; no automatic retry.") from None
        except (ValueError, UnicodeError):
            raise VerificationError("Sentry returned invalid JSON.") from None


def event_id(value) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[a-fA-F0-9]{32}", value):
        raise VerificationError("Expected a 32-character Sentry event ID.")
    return value.lower()


def read_manifest(path: Path) -> dict:
    try:
        manifest = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError, UnicodeError):
        raise VerificationError("Cannot read the verification JSON manifest.") from None
    if not isinstance(manifest, dict):
        raise VerificationError("The manifest must be a JSON object.")
    if manifest.get("environment") not in ("verification", "development"):
        raise VerificationError("Only verification/development manifests are supported.")
    release = manifest.get("release")
    if not isinstance(release, str) or not release.strip():
        raise VerificationError("The manifest must name an exact release.")
    events = manifest.get("event_ids")
    if not isinstance(events, list) or not 1 <= len(events) <= 1000:
        raise VerificationError("The manifest must list 1 to 1000 synthetic event IDs.")
    return {
        "environment": manifest["environment"],
        "release": release,
        "event_ids": sorted({event_id(item) for item in events}),
    }


def validate_event(event: dict, expected_id: str, manifest: dict) -> str:
    if event_id(event.get("eventID")) != expected_id:
        raise VerificationError("Sentry returned a different event.")
    tags = {item["key"]: item["value"] for item in event.get("tags", [])}
    release = event.get("release")
    if isinstance(release, dict):
        release = release.get("version")
    if tags.get("environment") != manifest["environment"] or release != manifest["release"]:
        raise VerificationError(f"Event {expected_id} has a different environment/release.")
    # Do not classify an unknown platform or native failure as a synthetic Dart
    # sample, even when its ID was accidentally included in the manifest.
    if event.get("platform") != "dart":
        raise VerificationError(f"Event {expected_id} is native or has an unknown platform.")
    for entry in event.get("entries", []):
        if entry.get("type") != "exception":
            continue
        for exception in entry.get("data", {}).get("values", []):
            mechanism = exception.get("mechanism") or {}
            if mechanism.get("type") in {"minidump", "seh", "signal", "mach", "native", "anr"}:
                raise VerificationError(f"Event {expected_id} contains a native exception.")
    group = str(event.get("groupID", ""))
    if not group.isascii() or not group.isdecimal():
        raise VerificationError(f"Event {expected_id} has no issue ID.")
    return group


def next_cursor(headers) -> str | None:
    for part in headers.get("Link", "").split(","):
        match = re.match(r'\s*<([^>]+)>(.*)', part)
        if not match:
            continue
        attributes = dict(re.findall(r';\s*(\w+)="([^"]*)"', match[2]))
        if attributes.get("rel") != "next" or attributes.get("results") != "true":
            continue
        # Use only the cursor; never forward authentication to a Link URL.
        values = parse_qs(urlsplit(match[1]).query).get("cursor", [])
        if len(values) != 1 or not values[0]:
            raise VerificationError("Sentry pagination omitted its next cursor.")
        return values[0]
    return None


def group_snapshot(group: dict):
    return tuple(group.get(key) for key in ("count", "firstSeen", "lastSeen", "status"))


def inspect_group(api, path: str, group_id: str, project_id: str, approved: set[str]) -> dict:
    result = {"issue_id": group_id, "event_ids": sorted(approved), "action": "skip"}
    group, _ = api.request(path)
    if str(group.get("project", {}).get("id")) != project_id:
        result["reason"] = "Issue belongs to another project."
        return result
    count = str(group.get("count", ""))
    if not count.isascii() or not count.isdecimal() or int(count) != len(approved):
        result["reason"] = "Lifetime count includes unlisted or unavailable events."
        return result
    found: set[str] = set()
    cursors: set[str] = set()
    query = {"per_page": "100"}
    while True:
        # No environment, release, date or sample filter: inspect the whole group.
        # If retention hides old events, the lifetime-count check below fails.
        events, headers = api.request(path + "events/", query=query)
        if not isinstance(events, list):
            raise VerificationError("Sentry returned an invalid event list.")
        for event in events:
            current_id = event_id(event.get("eventID"))
            if current_id not in approved or current_id in found:
                result["reason"] = "Issue contains unlisted events or unstable pagination."
                return result
            found.add(current_id)
        cursor = next_cursor(headers)
        if cursor is None:
            break
        if cursor in cursors or len(cursors) >= 100:
            raise VerificationError("Sentry pagination did not finish.")
        cursors.add(cursor)
        query["cursor"] = cursor
    if found != approved:
        result["reason"] = "The complete event history could not be verified."
        return result
    current, _ = api.request(path)
    if group_snapshot(current) != group_snapshot(group):
        result["reason"] = "Issue changed during inspection; run the preview again."
    elif current.get("status") == "resolved":
        result["action"] = "already-resolved"
    elif current.get("status") == "unresolved":
        result["action"] = "resolve"
    else:
        result["reason"] = "Issue is not unresolved; its existing status is preserved."
    return result


def run(api, org: str, project: str, manifest: dict, apply: bool) -> dict:
    project_path = f"projects/{org}/{project}/"
    project_info, _ = api.request(project_path)
    project_id = str(project_info["id"])
    groups: dict[str, set[str]] = {}
    # Validate every explicit sample before considering any remote mutation.
    for expected_id in manifest["event_ids"]:
        event, _ = api.request(f"{project_path}events/{expected_id}/")
        if str(event.get("projectID")) != project_id:
            raise VerificationError(f"Event {expected_id} belongs to another project.")
        group_id = validate_event(event, expected_id, manifest)
        groups.setdefault(group_id, set()).add(expected_id)
    paths = {group: f"organizations/{org}/issues/{group}/" for group in groups}
    results = [
        inspect_group(api, paths[group], group, project_id, approved)
        for group, approved in sorted(groups.items())
    ]
    report = {
        "mode": "apply" if apply else "preview",
        "organization": org,
        "project": project,
        "environment": manifest["environment"],
        "release": manifest["release"],
        "views": {
            environment: f"{api.origin}/organizations/{org}/issues/?"
            + urlencode({"project": project_id, "environment": environment, "query": "is:unresolved"})
            for environment in ("production", manifest["environment"])
        },
        "issues": results,
    }
    for index, result in enumerate(results):
        if result["action"] != "resolve":
            continue
        if not apply:
            result["action"] = "would-resolve"
            continue
        group = result["issue_id"]
        # A preview is not authorization to resolve a group that changed later.
        submitted = False
        try:
            result = inspect_group(api, paths[group], group, project_id, groups[group])
            results[index] = result
            if result["action"] == "resolve":
                submitted = True
                updated, _ = api.request(paths[group], body={"status": "resolved"})
                if updated.get("status") != "resolved":
                    raise VerificationError("Sentry did not confirm the resolved status.")
                result["action"] = "resolved"
        except (VerificationError, KeyError, TypeError, ValueError, AttributeError) as error:
            result["action"] = "unknown" if submitted else "skip"
            message = str(error) if isinstance(error, VerificationError) else "Unexpected Sentry response."
            result["reason"] = message + " Rerun the preview to check current status."
            # Preserve earlier results and stop after a failed/ambiguous response.
            for pending in results[index + 1 :]:
                if pending["action"] == "resolve":
                    pending["action"] = "skip"
                    pending["reason"] = "Stopped after an earlier request failed."
            break
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("manifest", type=Path, help="Private receipt listing confirmed synthetic event IDs.")
    parser.add_argument("--org", default="tkstudio")
    parser.add_argument("--project", default="xmplus")
    parser.add_argument("--url", default="https://sentry.io", help="Sentry HTTPS origin.")
    parser.add_argument("--apply", action="store_true", help="Resolve eligible groups after rechecking them.")
    args = parser.parse_args()
    try:
        for slug in (args.org, args.project):
            if not re.fullmatch(r"[a-zA-Z0-9_-]+", slug):
                raise VerificationError("Invalid organization/project slug.")
        manifest = read_manifest(args.manifest)
        token = os.environ.get("SENTRY_AUTH_TOKEN", "").strip()
        if not token:
            raise VerificationError("Set SENTRY_AUTH_TOKEN in the process environment.")
        report = run(SentryApi(args.url, token), args.org, args.project, manifest, args.apply)
        print(json.dumps(report, ensure_ascii=True, indent=2))
        return 2 if any(item["action"] in ("skip", "unknown") for item in report["issues"]) else 0
    except VerificationError as error:
        print(f"Verification cleanup stopped: {error}", file=sys.stderr)
        return 1
    except (KeyError, TypeError, ValueError, AttributeError):
        print("Verification cleanup stopped: unexpected Sentry response structure.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
