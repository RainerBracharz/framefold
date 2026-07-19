#!/usr/bin/env python3
"""Generiert ein vollständiges, öffnungsbereites Xcode-Projekt für FrameFold.

Erzeugt FrameFold.xcodeproj/project.pbxproj mit:
- allen Swift-Quellen aus FrameFold/
- automatischem Signing (Team wählt Rainer einmal in Xcode)
- generierter Info.plist inkl. Kamera-Berechtigung (INFOPLIST_KEY_...)
- iOS-17-Deployment-Target, Portrait, iPhone
"""
import hashlib
import os
import sys

ROOT = "/home/claude/FrameFold"
SRC_DIR = os.path.join(ROOT, "FrameFold")
PROJ_DIR = os.path.join(ROOT, "FrameFold.xcodeproj")

CAMERA_TEXT = ("FrameFold nimmt im Live-Modus automatisch Frames auf, "
               "wenn deine Hände aus dem Bild sind.")


def uid(name: str) -> str:
    """Deterministische 24-Hex-ID (Xcode-Format) aus einem Namen."""
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


sources = sorted(f for f in os.listdir(SRC_DIR) if f.endswith(".swift"))
if not sources:
    sys.exit("Keine Swift-Dateien gefunden")
print(f"{len(sources)} Quellen:", ", ".join(sources))

# IDs
ids = {
    "project": uid("PBXProject"),
    "mainGroup": uid("MainGroup"),
    "sourceGroup": uid("SourceGroup"),
    "productsGroup": uid("ProductsGroup"),
    "target": uid("NativeTarget"),
    "product": uid("AppProduct"),
    "sourcesPhase": uid("SourcesPhase"),
    "frameworksPhase": uid("FrameworksPhase"),
    "resourcesPhase": uid("ResourcesPhase"),
    "projDebug": uid("ProjDebug"),
    "projRelease": uid("ProjRelease"),
    "targetDebug": uid("TargetDebug"),
    "targetRelease": uid("TargetRelease"),
    "projConfigList": uid("ProjConfigList"),
    "targetConfigList": uid("TargetConfigList"),
}
file_refs = {f: uid("FileRef:" + f) for f in sources}
build_files = {f: uid("BuildFile:" + f) for f in sources}

# --- pbxproj-Inhalt ---
build_file_entries = "\n".join(
    f"\t\t{build_files[f]} /* {f} in Sources */ = {{isa = PBXBuildFile; "
    f"fileRef = {file_refs[f]} /* {f} */; }};"
    for f in sources)

file_ref_entries = "\n".join(
    f"\t\t{file_refs[f]} /* {f} */ = {{isa = PBXFileReference; "
    f"lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = \"<group>\"; }};"
    for f in sources)

source_children = "\n".join(
    f"\t\t\t\t{file_refs[f]} /* {f} */," for f in sources)

sources_phase_files = "\n".join(
    f"\t\t\t\t{build_files[f]} /* {f} in Sources */," for f in sources)

SHARED_PROJ_SETTINGS = """\
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 17.0;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MTL_FAST_MATH = YES;
				SDKROOT = iphoneos;
				SWIFT_VERSION = 5.0;"""

TARGET_SETTINGS = f"""\
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = "";
				ENABLE_PREVIEWS = YES;
				GENERATE_INFOPLIST_FILE = YES;
				INFOPLIST_KEY_NSCameraUsageDescription = "{CAMERA_TEXT}";
				INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES;
				INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents = YES;
				INFOPLIST_KEY_UILaunchScreen_Generation = YES;
				INFOPLIST_KEY_UISupportedInterfaceOrientations = UIInterfaceOrientationPortrait;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.rainer.framefold;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				TARGETED_DEVICE_FAMILY = 1;"""

pbxproj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 56;
	objects = {{

/* Begin PBXBuildFile section */
{build_file_entries}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{file_ref_entries}
		{ids['product']} /* FrameFold.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = FrameFold.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{ids['frameworksPhase']} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{ids['mainGroup']} = {{
			isa = PBXGroup;
			children = (
				{ids['sourceGroup']} /* FrameFold */,
				{ids['productsGroup']} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{ids['sourceGroup']} /* FrameFold */ = {{
			isa = PBXGroup;
			children = (
{source_children}
			);
			path = FrameFold;
			sourceTree = "<group>";
		}};
		{ids['productsGroup']} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{ids['product']} /* FrameFold.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{ids['target']} /* FrameFold */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {ids['targetConfigList']} /* Build configuration list for PBXNativeTarget "FrameFold" */;
			buildPhases = (
				{ids['sourcesPhase']} /* Sources */,
				{ids['frameworksPhase']} /* Frameworks */,
				{ids['resourcesPhase']} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = FrameFold;
			productName = FrameFold;
			productReference = {ids['product']} /* FrameFold.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{ids['project']} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1500;
				LastUpgradeCheck = 1500;
				TargetAttributes = {{
					{ids['target']} = {{
						CreatedOnToolsVersion = 15.0;
					}};
				}};
			}};
			buildConfigurationList = {ids['projConfigList']} /* Build configuration list for PBXProject "FrameFold" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = de;
			hasScannedForEncodings = 0;
			knownRegions = (
				de,
				en,
				Base,
			);
			mainGroup = {ids['mainGroup']};
			productRefGroup = {ids['productsGroup']} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{ids['target']} /* FrameFold */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{ids['resourcesPhase']} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{ids['sourcesPhase']} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources_phase_files}
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{ids['projDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{SHARED_PROJ_SETTINGS}
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{ids['projRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{SHARED_PROJ_SETTINGS}
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				SWIFT_COMPILATION_MODE = wholemodule;
				VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{ids['targetDebug']} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{TARGET_SETTINGS}
			}};
			name = Debug;
		}};
		{ids['targetRelease']} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
{TARGET_SETTINGS}
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{ids['projConfigList']} /* Build configuration list for PBXProject "FrameFold" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['projDebug']} /* Debug */,
				{ids['projRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{ids['targetConfigList']} /* Build configuration list for PBXNativeTarget "FrameFold" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{ids['targetDebug']} /* Debug */,
				{ids['targetRelease']} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {ids['project']} /* Project object */;
}}
"""

os.makedirs(PROJ_DIR, exist_ok=True)
with open(os.path.join(PROJ_DIR, "project.pbxproj"), "w") as fh:
    fh.write(pbxproj)

# workspace-Daten, damit Xcode das Projekt sauber öffnet
ws_dir = os.path.join(PROJ_DIR, "project.xcworkspace")
os.makedirs(ws_dir, exist_ok=True)
with open(os.path.join(ws_dir, "contents.xcworkspacedata"), "w") as fh:
    fh.write("""<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
""")

print("FrameFold.xcodeproj geschrieben")
