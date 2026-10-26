#!/usr/bin/env python3
"""Update only the mobile targets' explicit shared-source membership, leaving desktop intact.

The app embeds the Live Activity extension built from Sources/MobileActivity. `--check` reports a
project or app Info.plist that no longer matches the manifest instead of writing it.
"""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
PROJECT = ROOT / "Fluid.xcodeproj/project.pbxproj"
APP_INFO = ROOT / "Sources/Mobile/Info.plist"
VERSION_CONFIG = ROOT / "Sources/Mobile/Version.xcconfig"
# Debug and Release share one app identity. An embedded extension must extend it, so a local
# signing identity overrides this one setting rather than PRODUCT_BUNDLE_IDENTIFIER.
APP_BUNDLE = "ai.pichi.voice.mobile"

# The app declares Live Activity support; the plist keeps its compact hand-edited layout.
app_info_text = APP_INFO.read_text()
app_info = plistlib.loads(app_info_text.encode())
if app_info.get("NSSupportsLiveActivities") is not True:
    if "NSSupportsLiveActivities" in app_info or app_info_text.count("</dict></plist>") != 1:
        raise ValueError("Set NSSupportsLiveActivities to true in " + str(APP_INFO.relative_to(ROOT)))
    app_info_text = app_info_text.replace("</dict></plist>", "<key>NSSupportsLiveActivities</key><true/>\n</dict></plist>")
# The app and extension expand one shared configuration, including command-line
# release build overrides. Neither plist may override those settings with literals.
for key, setting in [("CFBundleShortVersionString", "MARKETING_VERSION"), ("CFBundleVersion", "CURRENT_PROJECT_VERSION")]:
    if app_info.get(key) != "$(" + setting + ")":
        raise ValueError(key + " must use the shared mobile version setting")
if not VERSION_CONFIG.is_file():
    raise ValueError("Missing shared mobile version configuration")

def uid(label):
    return hashlib.sha256(("PichiVoiceMobile:" + label).encode()).hexdigest()[:24].upper()

def quoted(value):
    return json.dumps(str(value))

objects = []
def obj(label, value):
    identifier = uid(label)
    objects.append(f"\t\t{identifier} /* {label} */ = {{ {value} }};\n")
    return identifier

def arr(values):
    return "(" + ", ".join(values) + (", " if values else "") + ")"

manifest = ROOT / "Sources/Mobile/shared-sources.txt"
sources = [line.strip() for line in manifest.read_text().splitlines() if line.strip() and not line.startswith("#")]
sources += [str(path.relative_to(ROOT)) for path in sorted((ROOT / "Sources/Mobile").glob("*.swift"))]
sources = list(dict.fromkeys(sources))
resource_paths = [
    "Sources/Fluid/Localization/Localizable.xcstrings", "Sources/Fluid/Assets.xcassets",
    "Sources/Fluid/Branding/brand-package.json", "Sources/Fluid/Resources/Notices",
    "Sources/Mobile/Resources/brand-distribution.json", "Sources/Mobile/Resources/MobileAssets.xcassets",
]
file_ids, source_builds, resource_builds = [], [], []
file_refs = {}
def file_ref(path, label="Mobile file "):
    if path not in file_refs:
        kind = {".swift":"sourcecode.swift", ".xcstrings":"text.json.xcstrings", ".xcassets":"folder.assetcatalog",
                ".strings":"text.plist.strings", ".json":"text.json", ".xcconfig":"text.xcconfig"}.get(Path(path).suffix, "folder")
        file_refs[path] = obj(label + path, f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quoted(path)}; sourceTree = SOURCE_ROOT;")
        file_ids.append(file_refs[path])
    return file_refs[path]

for path in sources + resource_paths:
    ref = file_ref(path)
    build = obj("Mobile build " + path, f"isa = PBXBuildFile; fileRef = {ref};")
    (source_builds if path in sources else resource_builds).append(build)

# Localized references have one physical resource parent. An empty-root variant
# would make CodeSign recursively consume the entire checkout, including test products.
locale_refs = []
for language in ("en", "ru"):
    locale_refs.append(obj("Mobile localized InfoPlist " + language,
        f'isa = PBXFileReference; lastKnownFileType = text.plist.strings; name = {language}; path = {quoted(language + ".lproj/InfoPlist.strings")}; sourceTree = "<group>";'))
variant = obj("Mobile InfoPlist.strings", f'isa = PBXVariantGroup; children = {arr(locale_refs)}; name = InfoPlist.strings; sourceTree = "<group>";')
localized_resources = obj("Mobile localized resources", f'isa = PBXGroup; children = {arr([variant])}; name = Resources; path = "Sources/Mobile/Resources"; sourceTree = SOURCE_ROOT;')
resource_builds.append(obj("Mobile InfoPlist.strings resource", f"isa = PBXBuildFile; fileRef = {variant};"))

package_products = []
framework_builds = []
for name, package in [("PichiGigaAM", "C41C41000000000000000001"), ("PichiTextPrivacy", "C41C41000000000000000001"),
                      ("FluidAudio", "7C078DA32E3B386A00FB7CAC"), ("TranscribeCpp", "7C9A71002F58B00000FB7CAF")]:
    product = obj("Mobile package " + name, f"isa = XCSwiftPackageProductDependency; package = {package}; productName = {name};")
    package_products.append(product)
    framework_builds.append(obj("Mobile framework " + name, f"isa = PBXBuildFile; productRef = {product};"))

source_phase = obj("Mobile Sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(source_builds)}; runOnlyForDeploymentPostprocessing = 0;")
resource_phase = obj("Mobile Resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr(resource_builds)}; runOnlyForDeploymentPostprocessing = 0;")
framework_phase = obj("Mobile Frameworks", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {arr(framework_builds)}; runOnlyForDeploymentPostprocessing = 0;")
product_ref = obj("PichiVoiceMobile.app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = PichiVoiceMobile.app; sourceTree = BUILT_PRODUCTS_DIR;')
version_ref = file_ref("Sources/Mobile/Version.xcconfig")

def configs(label, test=False, hosted=False, extension=False):
    config_ids = []
    for name in ("Debug", "Release"):
        settings = {
            "SDKROOT":"iphoneos", "SUPPORTED_PLATFORMS":"iphoneos iphonesimulator", "IPHONEOS_DEPLOYMENT_TARGET":"17.0",
            "TARGETED_DEVICE_FAMILY":"1,2", "SUPPORTS_MACCATALYST":"NO", "SWIFT_VERSION":"5.0",
            "SWIFT_STRICT_CONCURRENCY":"targeted", "SWIFT_DEFAULT_ACTOR_ISOLATION":"MainActor",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS":"$(inherited) MOBILE" + (" DEBUG" if name=="Debug" else ""),
            "PRODUCT_NAME":"$(TARGET_NAME)", "PRODUCT_BUNDLE_IDENTIFIER":APP_BUNDLE + (".integrationtests" if hosted else ".uitests" if test else ""),
            "ENABLE_TESTABILITY":"YES" if name=="Debug" else "NO",
            "PICHI_PRODUCT_NAME":json.loads((ROOT / "Sources/Fluid/Branding/brand-package.json").read_text())["profile"]["appName"],
            "CODE_SIGN_STYLE":"Automatic", "DEVELOPMENT_TEAM":"", "GENERATE_INFOPLIST_FILE":"YES" if test else "NO",
            "SWIFT_EMIT_LOC_STRINGS":"YES", "SWIFT_OPTIMIZATION_LEVEL":"-Onone" if name=="Debug" else "-O",
            "LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/Frameworks",
        }
        if hosted:
            settings.update(BUNDLE_LOADER="$(TEST_HOST)",
                TEST_HOST="$(BUILT_PRODUCTS_DIR)/PichiVoiceMobile.app/PichiVoiceMobile")
        elif test:
            settings.update(TEST_TARGET_NAME="PichiVoiceMobile", BUNDLE_LOADER="", TEST_HOST="")
        elif extension:
            # The extension has no String Catalog; the app passes it already localized copy.
            settings.update(PICHI_MOBILE_BUNDLE_IDENTIFIER=APP_BUNDLE, PRODUCT_BUNDLE_IDENTIFIER="$(PICHI_MOBILE_BUNDLE_IDENTIFIER).activity",
                INFOPLIST_FILE="Sources/MobileActivity/Info.plist",
                SKIP_INSTALL="YES", APPLICATION_EXTENSION_API_ONLY="YES", SWIFT_EMIT_LOC_STRINGS="NO",
                LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks")
        else:
            settings.update(PICHI_MOBILE_BUNDLE_IDENTIFIER=APP_BUNDLE, PRODUCT_BUNDLE_IDENTIFIER="$(PICHI_MOBILE_BUNDLE_IDENTIFIER)",
                INFOPLIST_FILE="Sources/Mobile/Info.plist", ASSETCATALOG_COMPILER_APPICON_NAME="MobileAppIcon",
                ENABLE_PREVIEWS="YES", PICHI_SOURCE_REVISION="unknown")
        rendered = " ".join(f"{key} = {quoted(value)};" for key, value in settings.items())
        base_configuration = "" if test else f"baseConfigurationReference = {version_ref}; "
        config_ids.append(obj(label+" "+name, f"isa = XCBuildConfiguration; {base_configuration}buildSettings = {{ {rendered} }}; name = {name};"))
    return obj(label+" configurations", f"isa = XCConfigurationList; buildConfigurations = {arr(config_ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

# WidgetKit Live Activity extension: every Swift file in Sources/MobileActivity plus the packaged
# brand mark asset catalog. The app compiles the shared attributes file through the manifest.
activity_builds = []
for path in sorted((ROOT / "Sources/MobileActivity").glob("*.swift")):
    relative = str(path.relative_to(ROOT))
    activity_builds.append(obj("Mobile activity build " + relative, f"isa = PBXBuildFile; fileRef = {file_ref(relative, 'Mobile activity file ')};"))
activity_sources = obj("Mobile activity Sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(activity_builds)}; runOnlyForDeploymentPostprocessing = 0;")
activity_resource = obj("Mobile activity resource Sources/Fluid/Assets.xcassets", f"isa = PBXBuildFile; fileRef = {file_ref('Sources/Fluid/Assets.xcassets')};")
activity_resources = obj("Mobile activity Resources", f"isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {arr([activity_resource])}; runOnlyForDeploymentPostprocessing = 0;")
activity_frameworks = obj("Mobile activity Frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
activity_product = obj("PichiVoiceMobileActivity.appex", 'isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; path = PichiVoiceMobileActivity.appex; sourceTree = BUILT_PRODUCTS_DIR;')
activity_config = configs("Mobile activity", extension=True)
activity_target = obj("PichiVoiceMobileActivity", f'isa = PBXNativeTarget; buildConfigurationList = {activity_config}; buildPhases = {arr([activity_sources, activity_frameworks, activity_resources])}; buildRules = (); dependencies = (); name = PichiVoiceMobileActivity; productName = PichiVoiceMobileActivity; productReference = {activity_product}; productType = "com.apple.product-type.app-extension";')
activity_proxy = obj("Mobile activity proxy", f"isa = PBXContainerItemProxy; containerPortal = 7C078D872E3B339200FB7CAC; proxyType = 1; remoteGlobalIDString = {activity_target}; remoteInfo = PichiVoiceMobileActivity;")
activity_dependency = obj("Mobile activity dependency", f"isa = PBXTargetDependency; target = {activity_target}; targetProxy = {activity_proxy};")
activity_embed = obj("Mobile embed PichiVoiceMobileActivity.appex", f"isa = PBXBuildFile; fileRef = {activity_product}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};")
embed_phase = obj("Mobile Embed Foundation Extensions", f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = {arr([activity_embed])}; name = "Embed Foundation Extensions"; runOnlyForDeploymentPostprocessing = 0;')

app_config = configs("Mobile")
app_target = obj("PichiVoiceMobile", f"isa = PBXNativeTarget; buildConfigurationList = {app_config}; buildPhases = {arr([source_phase, framework_phase, resource_phase, embed_phase])}; buildRules = (); dependencies = {arr([activity_dependency])}; name = PichiVoiceMobile; packageProductDependencies = {arr(package_products)}; productName = PichiVoiceMobile; productReference = {product_ref}; productType = \"com.apple.product-type.application\";")

test_builds = []
for path in sorted((ROOT / "Tests/MobileUITests").glob("*.swift")):
    relative = str(path.relative_to(ROOT))
    ref = obj("Mobile test file " + relative, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;")
    file_ids.append(ref)
    test_builds.append(obj("Mobile test build " + relative, f"isa = PBXBuildFile; fileRef = {ref};"))
test_sources = obj("Mobile test Sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(test_builds)}; runOnlyForDeploymentPostprocessing = 0;")
test_frameworks = obj("Mobile test Frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
test_product = obj("PichiVoiceMobileUITests.xctest", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = PichiVoiceMobileUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
proxy = obj("Mobile test proxy", f"isa = PBXContainerItemProxy; containerPortal = 7C078D872E3B339200FB7CAC; proxyType = 1; remoteGlobalIDString = {app_target}; remoteInfo = PichiVoiceMobile;")
dependency = obj("Mobile test dependency", f"isa = PBXTargetDependency; target = {app_target}; targetProxy = {proxy};")
test_config = configs("Mobile test", True)
test_target = obj("PichiVoiceMobileUITests", f'isa = PBXNativeTarget; buildConfigurationList = {test_config}; buildPhases = {arr([test_sources,test_frameworks])}; buildRules = (); dependencies = {arr([dependency])}; name = PichiVoiceMobileUITests; productName = PichiVoiceMobileUITests; productReference = {test_product}; productType = "com.apple.product-type.bundle.ui-testing";')
integration_builds = []
integration_paths = list((ROOT / "Tests/MobileIntegrationTests").glob("*.swift"))
for portable_name in ["MobileRegisteredModelInferenceTests.swift", "MeetingOwnerVoiceProfileTests.swift"]:
    portable_test = ROOT / "Tests/FluidDictationIntegrationTests" / portable_name
    if portable_test.is_file(): integration_paths.append(portable_test)
for path in sorted(integration_paths):
    relative = str(path.relative_to(ROOT))
    ref = obj("Mobile integration file " + relative, f"isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(relative)}; sourceTree = SOURCE_ROOT;")
    file_ids.append(ref)
    integration_builds.append(obj("Mobile integration build " + relative, f"isa = PBXBuildFile; fileRef = {ref};"))
integration_sources = obj("Mobile integration Sources", f"isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {arr(integration_builds)}; runOnlyForDeploymentPostprocessing = 0;")
integration_frameworks = obj("Mobile integration Frameworks", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
integration_product = obj("PichiVoiceMobileIntegrationTests.xctest", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = PichiVoiceMobileIntegrationTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
integration_config = configs("Mobile integration", True, True)
integration_target = obj("PichiVoiceMobileIntegrationTests", f'isa = PBXNativeTarget; buildConfigurationList = {integration_config}; buildPhases = {arr([integration_sources,integration_frameworks])}; buildRules = (); dependencies = {arr([dependency])}; name = PichiVoiceMobileIntegrationTests; productName = PichiVoiceMobileIntegrationTests; productReference = {integration_product}; productType = "com.apple.product-type.bundle.unit-test";')

mobile_group = obj("Mobile shared sources", f'isa = PBXGroup; children = {arr(file_ids+[localized_resources])}; name = Mobile; sourceTree = "<group>";')

text = PROJECT.read_text()
text = re.sub(r"\n/\* Begin Pichi mobile target \*/.*?/\* End Pichi mobile target \*/\n", "\n", text, flags=re.S)
for identifier in (app_target,test_target,integration_target,activity_target,product_ref,test_product,integration_product,activity_product,mobile_group):
    text = re.sub(r"\n\s*" + identifier + r" /\* Pichi mobile membership \*/,", "", text)
block = "\n/* Begin Pichi mobile target */\n" + "".join(objects) + "/* End Pichi mobile target */\n"
text = re.sub(r"(\tobjects = \{\n)\n*", lambda match: match.group(1), text, count=1)
text = text.replace("\tobjects = {\n", "\tobjects = {\n" + block, 1)
# This edits only the original main/product groups and project targets lists.
for original_id, additions, marker in [("7C078D862E3B339200FB7CAC", [mobile_group], "children"),
                                      ("7C078D902E3B339200FB7CAC", [product_ref,test_product,integration_product,activity_product], "children"),
                                      ("7C078D872E3B339200FB7CAC", [app_target,test_target,integration_target,activity_target], "targets")]:
    pattern = r"(" + original_id + r"(?: /\*[^*]*\*/)? = \{.*?" + marker + r" = \()"
    insertion = "".join("\n\t\t\t\t" + identifier + " /* Pichi mobile membership */," for identifier in additions)
    text, count = re.subn(pattern, lambda match: match.group(1)+insertion, text, count=1, flags=re.S)
    if count != 1: raise ValueError("Original project structure not found: " + original_id)

scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="PichiVoiceMobile.app" BlueprintName="PichiVoiceMobile" ReferencedContainer="container:Fluid.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="PichiVoiceMobileUITests.xctest" BlueprintName="PichiVoiceMobileUITests" ReferencedContainer="container:Fluid.xcodeproj"/></TestableReference><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{integration_target}" BuildableName="PichiVoiceMobileIntegrationTests.xctest" BlueprintName="PichiVoiceMobileIntegrationTests" ReferencedContainer="container:Fluid.xcodeproj"/></TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="PichiVoiceMobile.app" BlueprintName="PichiVoiceMobile" ReferencedContainer="container:Fluid.xcodeproj"/></BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_target}" BuildableName="PichiVoiceMobile.app" BlueprintName="PichiVoiceMobile" ReferencedContainer="container:Fluid.xcodeproj"/></BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
SCHEME = ROOT / "Fluid.xcodeproj/xcshareddata/xcschemes/PichiVoiceMobile.xcscheme"
if "--check" in sys.argv[1:]:
    if (PROJECT.read_text() != text or not SCHEME.exists() or SCHEME.read_text() != scheme
            or APP_INFO.read_text() != app_info_text):
        sys.exit("The mobile target differs from Sources/Mobile/shared-sources.txt. Run python3 scripts/dev/update-mobile-project.py.")
    print("Mobile target matches Sources/Mobile/shared-sources.txt")
    sys.exit(0)
PROJECT.write_text(text)
SCHEME.write_text(scheme)
APP_INFO.write_text(app_info_text)
print(f"Mobile target: {len(sources)} shared and platform Swift files, {len(test_builds)} UI and {len(integration_builds)} hosted integration test files, "
      f"{len(activity_builds)} Live Activity extension files")
