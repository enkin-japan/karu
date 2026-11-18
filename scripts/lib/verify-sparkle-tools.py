#!/usr/bin/env python3
"""Release gate: locate Sparkle's sign_update and prove which Sparkle it is.

Usage: verify-sparkle-tools.py <Package.resolved> <.build directory>

The tool used is the one SwiftPM unpacked from Sparkle's binary artifact
(<.build>/artifacts/sparkle/Sparkle/bin/sign_update). SwiftPM verified that
archive against the checksum declared in Sparkle's own Package.swift, so no
download happens here. This script checks that everything on disk belongs to
the version pinned in Package.resolved:

  1. Package.resolved pins sparkle at version V, revision R.
  2. <.build>/workspace-state.json has the sparkle checkout at revision R and a
     sparkle artifact whose URL is the release asset of V, with checksum C.
  3. <.build>/checkouts/Sparkle is at revision R and its Package.swift
     declares checksum C.
  4. bin/sign_update exists and is executable.

On success prints four `key=value` lines (path, version, revision,
artifact_checksum) on stdout and exits 0. On any mismatch prints the reason on
stderr and exits 1. Writes nothing.
"""
import json
import os
import re
import subprocess
import sys


def fail(message: str) -> int:
    print("Sparkle 工具核对失败：" + message, file=sys.stderr)
    return 1


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    resolved_path, build_dir = sys.argv[1], sys.argv[2]

    try:
        with open(resolved_path, encoding="utf-8") as handle:
            resolved = json.load(handle)
    except (OSError, ValueError) as error:
        return fail(f"读不出 {resolved_path}（{error}）")
    pins = [pin for pin in resolved.get("pins", []) if pin.get("identity") == "sparkle"]
    if len(pins) != 1:
        return fail(f"{resolved_path} 里应当恰好有一条 sparkle 记录，实际 {len(pins)} 条")
    version = pins[0].get("state", {}).get("version")
    revision = pins[0].get("state", {}).get("revision")
    if not version or not revision:
        return fail("Package.resolved 的 sparkle 记录缺少 version 或 revision")

    state_path = os.path.join(build_dir, "workspace-state.json")
    try:
        with open(state_path, encoding="utf-8") as handle:
            state = json.load(handle).get("object", {})
    except (OSError, ValueError) as error:
        return fail(f"读不出 {state_path}（{error}）；先运行 swift build")

    checkouts = [dep for dep in state.get("dependencies", [])
                 if dep.get("packageRef", {}).get("identity") == "sparkle"]
    if len(checkouts) != 1:
        return fail("workspace-state.json 里没有唯一的 sparkle 依赖记录；先运行 swift build")
    checkout_state = checkouts[0].get("state", {}).get("checkoutState", {})
    if checkout_state.get("revision") != revision:
        return fail(f"已检出的 Sparkle 修订 {checkout_state.get('revision')!r} 与 Package.resolved 的 {revision!r} 不符")

    artifacts = [item for item in state.get("artifacts", [])
                 if item.get("packageRef", {}).get("identity") == "sparkle"]
    if len(artifacts) != 1:
        return fail("workspace-state.json 里没有唯一的 sparkle 二进制产物记录；先运行 swift build")
    source = artifacts[0].get("source", {})
    url = source.get("url", "")
    checksum = source.get("checksum", "")
    expected_url_part = f"/releases/download/{version}/"
    if not url.startswith("https://github.com/sparkle-project/Sparkle/") or expected_url_part not in url:
        return fail(f"二进制产物的来源 {url!r} 不是 {version} 版的发布资产")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        return fail(f"二进制产物没有有效的校验值：{checksum!r}")

    checkout_dir = os.path.join(build_dir, "checkouts", "Sparkle")
    try:
        head = subprocess.run(["git", "-C", checkout_dir, "rev-parse", "HEAD"],
                              check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError) as error:
        return fail(f"读不出 {checkout_dir} 的修订（{error}）")
    if head != revision:
        return fail(f"{checkout_dir} 位于 {head}，不是 Package.resolved 的 {revision}")
    try:
        with open(os.path.join(checkout_dir, "Package.swift"), encoding="utf-8") as handle:
            manifest = handle.read()
    except OSError as error:
        return fail(f"读不出 Sparkle 的 Package.swift（{error}）")
    declared = re.search(r'let\s+checksum\s*=\s*"([0-9a-f]{64})"', manifest)
    if not declared:
        return fail("在 Sparkle 的 Package.swift 里找不到 checksum 声明")
    if declared.group(1) != checksum:
        return fail(f"产物校验值 {checksum} 与 Sparkle Package.swift 声明的 {declared.group(1)} 不符")

    tool = os.path.join(build_dir, "artifacts", "sparkle", "Sparkle", "bin", "sign_update")
    if not (os.path.isfile(tool) and os.access(tool, os.X_OK)):
        return fail(f"找不到可执行的 {tool}；先运行 swift build")

    print(f"path={tool}")
    print(f"version={version}")
    print(f"revision={revision}")
    print(f"artifact_checksum={checksum}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
