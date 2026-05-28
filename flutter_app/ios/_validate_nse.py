#!/usr/bin/env python3
"""Validate the NSE surgery on Runner.xcodeproj/project.pbxproj.

Fails loudly (non-zero exit + FAIL summary) if any structural assertion breaks.
Run standalone after _add_nse.py, or invoked automatically by it.
"""

import os
import sys

from pbxproj import XcodeProject
from openstep_parser import OpenStepDecoder

PROJECT = "Runner.xcodeproj/project.pbxproj"
NSE_NAME = "NotificationService"
NSE_BUNDLE_ID = "com.example.kirca.NotificationService"
APPEX = "NotificationService.appex"

checks = []


def check(label, ok):
    checks.append((label, bool(ok)))
    print(f"[{'PASS' if ok else 'FAIL'}] {label}")


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)

    # 1. mod-pbxproj must reload the saved file without throwing.
    try:
        project = XcodeProject.load(PROJECT)
        check("XcodeProject.load() reloads saved file", True)
    except Exception as e:  # noqa: BLE001
        check(f"XcodeProject.load() reloads saved file ({e})", False)
        return summarize()

    # 2. Raw openstep_parser must parse the file directly.
    try:
        with open(PROJECT, "r", encoding="utf-8") as fh:
            OpenStepDecoder.ParseFromString(fh.read())
        check("openstep_parser parses raw file", True)
    except Exception as e:  # noqa: BLE001
        check(f"openstep_parser parses raw file ({e})", False)

    # 3. Exactly 3 PBXNativeTargets.
    native = list(project.objects.get_objects_in_section("PBXNativeTarget"))
    names = sorted(getattr(t, "name", "?") for t in native)
    check(f"exactly 3 PBXNativeTargets (got {len(native)}: {names})", len(native) == 3)

    nse = next((t for t in native if getattr(t, "name", None) == NSE_NAME), None)
    runner = next((t for t in native if getattr(t, "name", None) == "Runner"), None)
    check("NotificationService target exists", nse is not None)
    check("Runner target exists", runner is not None)

    if nse is None or runner is None:
        return summarize()

    # 4. NSE productType is app-extension.
    check(
        "NSE productType is app-extension",
        getattr(nse, "productType", None) == "com.apple.product-type.app-extension",
    )

    # 5. NSE has Debug + Release configs with correct bundle id / plist / entitlements.
    cfg_list = project.objects[nse.buildConfigurationList]
    cfg_by_name = {}
    for cid in cfg_list.buildConfigurations:
        c = project.objects[cid]
        cfg_by_name[c.name] = c.buildSettings

    for cfg_name in ("Debug", "Release"):
        bs = cfg_by_name.get(cfg_name)
        check(f"NSE {cfg_name} config exists", bs is not None)
        if bs is None:
            continue
        check(
            f"NSE {cfg_name} PRODUCT_BUNDLE_IDENTIFIER == {NSE_BUNDLE_ID}",
            bs.get("PRODUCT_BUNDLE_IDENTIFIER", None) == NSE_BUNDLE_ID,
        )
        check(
            f"NSE {cfg_name} INFOPLIST_FILE == NotificationService/Info.plist",
            bs.get("INFOPLIST_FILE", None) == "NotificationService/Info.plist",
        )
        check(
            f"NSE {cfg_name} CODE_SIGN_ENTITLEMENTS set",
            bs.get("CODE_SIGN_ENTITLEMENTS", None)
            == "NotificationService/NotificationService.entitlements",
        )

    # 6. NSE sources phase contains NotificationService.swift.
    swift_in_sources = False
    for phase_id in nse.buildPhases:
        phase = project.objects[phase_id]
        if phase.get("isa", None) != "PBXSourcesBuildPhase":
            continue
        for bf_id in phase.get("files", []):
            bf = project.objects[bf_id]
            ref = project.objects[bf.fileRef]
            if ref.get("path", None) == "NotificationService.swift":
                swift_in_sources = True
    check("NotificationService.swift in NSE Sources phase", swift_in_sources)

    # 7. Runner has a copy-files phase with dstSubfolderSpec 13 referencing the appex.
    embed_ok = False
    for phase_id in runner.buildPhases:
        phase = project.objects[phase_id]
        if phase.get("isa", None) != "PBXCopyFilesBuildPhase":
            continue
        if str(phase.get("dstSubfolderSpec", None)) != "13":
            continue
        for bf_id in phase.get("files", []):
            bf = project.objects[bf_id]
            ref = project.objects[bf.fileRef]
            if ref.get("path", None) == APPEX:
                embed_ok = True
    check("Runner has Embed App Extensions phase (spec 13) with appex", embed_ok)

    # 8. Target dependency Runner -> NotificationService exists.
    dep_ok = False
    for dep_id in getattr(runner, "dependencies", []):
        dep = project.objects[dep_id]
        if dep.get("target", None) == nse.get_id():
            dep_ok = True
    check("Runner depends on NotificationService (PBXTargetDependency)", dep_ok)

    # 9. NSE registered in PBXProject.targets.
    proj_targets = project.objects[project.rootObject].targets
    check("NSE in PBXProject.targets", nse.get_id() in proj_targets)

    return summarize()


def summarize():
    passed = sum(1 for _, ok in checks if ok)
    total = len(checks)
    print("\n" + "=" * 60)
    if passed == total:
        print(f"RESULT: PASS ({passed}/{total} assertions)")
        return 0
    print(f"RESULT: FAIL ({passed}/{total} assertions passed)")
    for label, ok in checks:
        if not ok:
            print(f"  - FAILED: {label}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
