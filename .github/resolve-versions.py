#!/usr/bin/env python3
"""Resolve the latest stable and pre-release versions of zfs-autobackup from
PyPI and emit a build matrix (GitHub Actions outputs `matrix` and `any`).

A channel is included in the matrix if FORCE=true or its version tag is not
yet published on ghcr.io, so scheduled runs no-op when there is nothing new.
"""

import json
import os
import sys
import urllib.error
import urllib.request

from packaging.version import InvalidVersion, Version

PYPI_URL = "https://pypi.org/pypi/zfs-autobackup/json"
IMAGE = os.environ.get("IMAGE_NAME", "patte/zfs-autobackup")

MANIFEST_ACCEPT = ",".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)


def fetch_json(url, headers=None):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def tag_exists(tag):
    token = fetch_json(f"https://ghcr.io/token?scope=repository:{IMAGE}:pull")["token"]
    req = urllib.request.Request(
        f"https://ghcr.io/v2/{IMAGE}/manifests/{tag}",
        method="HEAD",
        headers={"Authorization": f"Bearer {token}", "Accept": MANIFEST_ACCEPT},
    )
    try:
        urllib.request.urlopen(req, timeout=30)
        return True
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return False
        raise


def resolve_versions():
    """Return (stable, pre) as the original PyPI version strings.

    `pre` is the newest release overall, so it equals `stable` when no
    pre-release is newer than the latest stable release.
    """
    releases = fetch_json(PYPI_URL)["releases"]
    versions = {}
    for release, files in releases.items():
        if not files or all(f.get("yanked") for f in files):
            continue
        try:
            versions[Version(release)] = release
        except InvalidVersion:
            continue
    stable = max(v for v in versions if not v.is_prerelease)
    latest = max(versions)
    return versions[stable], versions[latest]


def main():
    force = os.environ.get("FORCE") == "true"
    stable, pre = resolve_versions()

    matrix = []
    stable_tags = ["latest", "main", stable] + (["pre"] if pre == stable else [])
    if force or not tag_exists(stable):
        matrix.append({"channel": "stable", "version": stable, "tags": stable_tags})
    if pre != stable and (force or not tag_exists(pre)):
        matrix.append({"channel": "pre", "version": pre, "tags": ["pre", pre]})

    for entry in matrix:
        entry["tags"] = "\n".join(f"type=raw,value={t}" for t in entry["tags"])

    built = {e["channel"] for e in matrix}
    summary = (
        f"stable: `{stable}` {'→ build' if 'stable' in built else '→ up to date, skipped'}\n\n"
        f"pre: `{pre}` "
        + (
            "→ same as stable"
            if pre == stable
            else ("→ build" if "pre" in built else "→ up to date, skipped")
        )
        + f"\n\nforce: {force}\n"
    )
    print(summary)
    with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
        fh.write(summary)
    with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
        fh.write(f"matrix={json.dumps(matrix)}\n")
        fh.write(f"any={'true' if matrix else 'false'}\n")


if __name__ == "__main__":
    sys.exit(main())
