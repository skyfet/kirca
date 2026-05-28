#!/usr/bin/env python3
"""Add the NotificationService (NSE) app-extension target to Runner.xcodeproj.

Uses mod-pbxproj's low-level object model (the core-only install has no
add_target helper). Objects are built with each section's `.create()` factory
where one exists, otherwise via `cls().parse({...})` (the same shape the
factories use). IDs are assigned by the section classes' `_generate_id()`.

The script guards against double-adds (fails loudly if an NSE target already
exists) so a stray re-run can't duplicate objects.

Run from flutter_app/ios:
    python3 _add_nse.py
It saves the project then invokes _validate_nse.py and exits with its code.
"""

import os
import subprocess
import sys

from pbxproj import XcodeProject
from pbxproj.pbxsections import (
    PBXBuildFile,
    PBXContainerItemProxy,
    PBXCopyFilesBuildPhase,
    PBXFileReference,
    PBXFrameworksBuildPhase,
    PBXGroup,
    PBXNativeTarget,
    PBXResourcesBuildPhase,
    PBXSourcesBuildPhase,
    PBXTargetDependency,
    XCBuildConfiguration,
    XCConfigurationList,
)

PROJECT = "Runner.xcodeproj/project.pbxproj"
NSE_NAME = "NotificationService"
NSE_BUNDLE_ID = "com.example.kirca.NotificationService"
TEAM = "6A73838297"
APPEX = "NotificationService.appex"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    os.chdir(here)

    project = XcodeProject.load(PROJECT)
    objs = project.objects

    # ---- guard: don't double-add -----------------------------------------
    for t in objs.get_objects_in_section("PBXNativeTarget"):
        if getattr(t, "name", None) == NSE_NAME:
            print(f"FAIL: target {NSE_NAME!r} already exists; aborting.")
            sys.exit(1)

    # ---- locate Runner + mirror its deployment/version settings ----------
    runner = next(
        (t for t in objs.get_objects_in_section("PBXNativeTarget")
         if getattr(t, "name", None) == "Runner"),
        None,
    )
    if runner is None:
        print("FAIL: could not find Runner target.")
        sys.exit(1)

    deployment_target = "13.0"
    device_family = "1,2"
    for cfg_id in objs[runner.buildConfigurationList].buildConfigurations:
        bs = objs[cfg_id].buildSettings
        deployment_target = bs.get("IPHONEOS_DEPLOYMENT_TARGET", deployment_target)
        device_family = bs.get("TARGETED_DEVICE_FAMILY", device_family)

    # ---- file references --------------------------------------------------
    swift_ref = PBXFileReference.create("NotificationService.swift", "<group>")
    swift_ref["lastKnownFileType"] = "sourcecode.swift"
    swift_ref["fileEncoding"] = 4

    info_ref = PBXFileReference.create("Info.plist", "<group>")
    info_ref["lastKnownFileType"] = "text.plist.xml"

    ent_ref = PBXFileReference.create("NotificationService.entitlements", "<group>")
    ent_ref["lastKnownFileType"] = "text.plist.entitlements"

    appex_ref = PBXFileReference.create(APPEX, "BUILT_PRODUCTS_DIR")
    appex_ref["explicitFileType"] = "wrapper.app-extension"
    appex_ref["includeInIndex"] = 0
    # A built product has no on-disk path/name beyond the wrapper name.
    if "name" in appex_ref:
        del appex_ref["name"]

    for ref in (swift_ref, info_ref, ent_ref, appex_ref):
        objs[ref.get_id()] = ref

    # ---- group for the NSE sources ---------------------------------------
    nse_group = PBXGroup.create(
        path=NSE_NAME,
        children=[swift_ref.get_id(), info_ref.get_id(), ent_ref.get_id()],
    )
    objs[nse_group.get_id()] = nse_group

    root = objs[project.rootObject]
    objs[root.mainGroup].children.append(nse_group.get_id())
    objs[root.productRefGroup].children.append(appex_ref.get_id())

    # ---- compile NotificationService.swift -------------------------------
    swift_bf = PBXBuildFile.create(swift_ref)
    objs[swift_bf.get_id()] = swift_bf

    # ---- build phases for the NSE target ---------------------------------
    sources_phase = PBXSourcesBuildPhase.create(files=[swift_bf.get_id()])
    frameworks_phase = PBXFrameworksBuildPhase.create()
    resources_phase = PBXResourcesBuildPhase.create()
    for p in (sources_phase, frameworks_phase, resources_phase):
        objs[p.get_id()] = p

    # ---- XCBuildConfiguration (Debug / Release / Profile) ----------------
    def make_cfg(name, debug):
        bs = {
            "CODE_SIGN_ENTITLEMENTS":
                "NotificationService/NotificationService.entitlements",
            "CODE_SIGN_STYLE": "Automatic",
            "CURRENT_PROJECT_VERSION": "$(FLUTTER_BUILD_NUMBER)",
            "DEVELOPMENT_TEAM": TEAM,
            "GENERATE_INFOPLIST_FILE": "NO",
            "INFOPLIST_FILE": "NotificationService/Info.plist",
            "IPHONEOS_DEPLOYMENT_TARGET": deployment_target,
            "MARKETING_VERSION": "$(FLUTTER_BUILD_NAME)",
            "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE" if debug else "NO",
            "PRODUCT_BUNDLE_IDENTIFIER": NSE_BUNDLE_ID,
            "PRODUCT_NAME": "$(TARGET_NAME)",
            "SKIP_INSTALL": "YES",
            "SWIFT_VERSION": "5.0",
            "TARGETED_DEVICE_FAMILY": device_family,
            "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if debug else "-O",
        }
        if debug:
            bs["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        return XCBuildConfiguration().parse({
            "_id": XCBuildConfiguration._generate_id(),
            "isa": "XCBuildConfiguration",
            "name": name,
            "buildSettings": bs,
        })

    debug_cfg = make_cfg("Debug", True)
    release_cfg = make_cfg("Release", False)
    profile_cfg = make_cfg("Profile", False)
    for c in (debug_cfg, release_cfg, profile_cfg):
        objs[c.get_id()] = c

    cfg_list = XCConfigurationList().parse({
        "_id": XCConfigurationList._generate_id(),
        "isa": "XCConfigurationList",
        "buildConfigurations": [
            debug_cfg.get_id(), release_cfg.get_id(), profile_cfg.get_id(),
        ],
        "defaultConfigurationIsVisible": 0,
        "defaultConfigurationName": "Release",
    })
    objs[cfg_list.get_id()] = cfg_list

    # ---- the NSE native target -------------------------------------------
    nse_target = PBXNativeTarget().parse({
        "_id": PBXNativeTarget._generate_id(),
        "isa": "PBXNativeTarget",
        "buildConfigurationList": cfg_list.get_id(),
        "buildPhases": [
            sources_phase.get_id(),
            frameworks_phase.get_id(),
            resources_phase.get_id(),
        ],
        "buildRules": [],
        "dependencies": [],
        "name": NSE_NAME,
        "productName": NSE_NAME,
        "productReference": appex_ref.get_id(),
        "productType": "com.apple.product-type.app-extension",
    })
    objs[nse_target.get_id()] = nse_target

    # register on the project
    root.targets.append(nse_target.get_id())

    # ---- Runner -> NSE: embed appex + target dependency ------------------
    # Code-sign-on-copy + strip headers, the standard embed-extension flags.
    embed_bf = PBXBuildFile.create(
        appex_ref, attributes=["RemoveHeadersOnCopy", "CodeSignOnCopy"]
    )
    objs[embed_bf.get_id()] = embed_bf

    embed_phase = PBXCopyFilesBuildPhase.create(
        name="Embed App Extensions",
        files=[embed_bf.get_id()],
        dest_path="",
        dest_subfolder_spec=13,  # PlugIns / Extensions
    )
    objs[embed_phase.get_id()] = embed_phase
    runner.buildPhases.append(embed_phase.get_id())

    # Container item proxy: proxyType 1 (target dependency), remoteGlobalIDString
    # is the NSE TARGET id (not its product), matching the existing RunnerTests
    # dependency proxy in this project.
    proxy = PBXContainerItemProxy().parse({
        "_id": PBXContainerItemProxy._generate_id(),
        "isa": "PBXContainerItemProxy",
        "containerPortal": project.rootObject,
        "proxyType": 1,
        "remoteGlobalIDString": nse_target.get_id(),
        "remoteInfo": NSE_NAME,
    })
    objs[proxy.get_id()] = proxy

    dep = PBXTargetDependency().parse({
        "_id": PBXTargetDependency._generate_id(),
        "isa": "PBXTargetDependency",
        "target": nse_target.get_id(),
        "targetProxy": proxy.get_id(),
    })
    objs[dep.get_id()] = dep
    runner.dependencies.append(dep.get_id())

    # Mirror TargetAttributes so Xcode treats the new target as managed.
    attrs = root.attributes
    if "TargetAttributes" in attrs:
        attrs["TargetAttributes"][nse_target.get_id()] = {
            "CreatedOnToolsVersion": "15.0",
        }

    project.save()
    print("SAVED project.pbxproj")

    rc = subprocess.call([sys.executable, "_validate_nse.py"])
    sys.exit(rc)


if __name__ == "__main__":
    main()
