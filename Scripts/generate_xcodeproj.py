import hashlib, os, sys
root = sys.argv[1]
def gid(name): return hashlib.md5(name.encode()).hexdigest()[:24].upper()
app_dir = 'App/Pongo'
groups = {}  # path -> list of children
swift_files = []
for dp, dn, fn in os.walk(os.path.join(root, app_dir)):
    dn.sort(); 
    rel = os.path.relpath(dp, root)
    if rel.endswith('.xcassets') or '.xcassets/' in rel: continue
    for f in sorted(fn):
        if f.endswith('.swift'): swift_files.append(os.path.join(rel, f))
subgroups = ['App', 'Interface', 'Rendering', 'Audio', 'Resources']
objs = []
def add(s): objs.append(s)
fileref = {}
for f in swift_files:
    fileref[f] = gid('ref:' + f)
assets = 'App/Pongo/Resources/Assets.xcassets'
plist = 'App/Pongo/Resources/Info.plist'
fileref[assets] = gid('ref:' + assets)
fileref[plist] = gid('ref:' + plist)
product = gid('product:Pongo.app')
proj = gid('project'); target = gid('target:Pongo')
srcPhase = gid('phase:sources'); fwPhase = gid('phase:frameworks'); resPhase = gid('phase:resources')
mainGroup = gid('group:main'); productsGroup = gid('group:products'); appGroup = gid('group:App/Pongo')
pkgRef = gid('pkg:SpinCore'); pkgDep = gid('pkgdep:SpinCore'); pkgBuild = gid('build:SpinCore')
cfgListProj = gid('cfglist:project'); cfgListTarget = gid('cfglist:target')
cfg = {k: gid('cfg:' + k) for k in ['projDebug', 'projRelease', 'tDebug', 'tRelease']}
out = []
w = out.append
w('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 60;\n\tobjects = {\n')
w('\n/* Begin PBXBuildFile section */\n')
for f in swift_files:
    w(f'\t\t{gid("build:"+f)} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {fileref[f]} /* {os.path.basename(f)} */; }};\n')
w(f'\t\t{gid("build:"+assets)} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {fileref[assets]} /* Assets.xcassets */; }};\n')
w(f'\t\t{pkgBuild} /* SpinCore in Frameworks */ = {{isa = PBXBuildFile; productRef = {pkgDep} /* SpinCore */; }};\n')
w('/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */\n')
for f in swift_files:
    n = os.path.basename(f)
    w(f'\t\t{fileref[f]} /* {n} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {n}; sourceTree = "<group>"; }};\n')
w(f'\t\t{fileref[assets]} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};\n')
w(f'\t\t{fileref[plist]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};\n')
w(f'\t\t{product} /* Pongo.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Pongo.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n')
w('/* End PBXFileReference section */\n\n/* Begin PBXFrameworksBuildPhase section */\n')
w(f'\t\t{fwPhase} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{pkgBuild} /* SpinCore in Frameworks */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
w('/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */\n')
w(f'\t\t{mainGroup} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{appGroup} /* Pongo */,\n\t\t\t\t{productsGroup} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
w(f'\t\t{productsGroup} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{product} /* Pongo.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
sg_ids = {s: gid('group:' + s) for s in subgroups}
w(f'\t\t{appGroup} /* Pongo */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n')
for s in subgroups: w(f'\t\t\t\t{sg_ids[s]} /* {s} */,\n')
w(f'\t\t\t);\n\t\t\tpath = App/Pongo;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
for s in subgroups:
    kids = [f for f in swift_files if f.startswith(f'{app_dir}/{s}/')]
    if s == 'Resources': kids += [assets, plist]
    w(f'\t\t{sg_ids[s]} /* {s} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n')
    for k in kids: w(f'\t\t\t\t{fileref[k]} /* {os.path.basename(k)} */,\n')
    w(f'\t\t\t);\n\t\t\tpath = {s};\n\t\t\tsourceTree = "<group>";\n\t\t}};\n')
w('/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */\n')
w(f'''\t\t{target} /* Pongo */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {cfgListTarget} /* Build configuration list for PBXNativeTarget "Pongo" */;
\t\t\tbuildPhases = (
\t\t\t\t{srcPhase} /* Sources */,
\t\t\t\t{fwPhase} /* Frameworks */,
\t\t\t\t{resPhase} /* Resources */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Pongo;
\t\t\tpackageProductDependencies = (
\t\t\t\t{pkgDep} /* SpinCore */,
\t\t\t);
\t\t\tproductName = Pongo;
\t\t\tproductReference = {product} /* Pongo.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
''')
w('/* End PBXNativeTarget section */\n\n/* Begin PBXProject section */\n')
w(f'''\t\t{proj} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1500;
\t\t\t\tLastUpgradeCheck = 1500;
\t\t\t\tORGANIZATIONNAME = "Cnmbuck Studios";
\t\t\t\tTargetAttributes = {{
\t\t\t\t\t{target} = {{
\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;
\t\t\t\t\t}};
\t\t\t\t}};
\t\t\t}};
\t\t\tbuildConfigurationList = {cfgListProj} /* Build configuration list for PBXProject "Pongo" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {mainGroup};
\t\t\tpackageReferences = (
\t\t\t\t{pkgRef} /* XCLocalSwiftPackageReference "Packages/SpinCore" */,
\t\t\t);
\t\t\tproductRefGroup = {productsGroup} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{target} /* Pongo */,
\t\t\t);
\t\t}};
''')
w('/* End PBXProject section */\n\n/* Begin PBXResourcesBuildPhase section */\n')
w(f'\t\t{resPhase} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t\t{gid("build:"+assets)} /* Assets.xcassets in Resources */,\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n')
w('/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */\n')
w(f'\t\t{srcPhase} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n')
for f in swift_files: w(f'\t\t\t\t{gid("build:"+f)} /* {os.path.basename(f)} in Sources */,\n')
w('\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n')
w('/* End PBXSourcesBuildPhase section */\n\n/* Begin XCBuildConfiguration section */\n')
common = '''\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_VERSION = 5.0;
'''
w(f'''\t\t{cfg["projDebug"]} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{common}\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{cfg["projRelease"]} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
{common}\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tENABLE_NS_ASSERTIONS = NO;
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-O";
\t\t\t\tVALIDATE_PRODUCT = YES;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
''')
tcommon = '''\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = App/Pongo/Resources/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.cnmbuck.pongo;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSUPPORTS_MACCATALYST = NO;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = NO;
\t\t\t\tTARGETED_DEVICE_FAMILY = 1;
'''
for k, name in [('tDebug', 'Debug'), ('tRelease', 'Release')]:
    w(f'\t\t{cfg[k]} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{tcommon}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};\n')
w('/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */\n')
w(f'''\t\t{cfgListProj} /* Build configuration list for PBXProject "Pongo" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{cfg["projDebug"]} /* Debug */,
\t\t\t\t{cfg["projRelease"]} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{cfgListTarget} /* Build configuration list for PBXNativeTarget "Pongo" */ = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = (
\t\t\t\t{cfg["tDebug"]} /* Debug */,
\t\t\t\t{cfg["tRelease"]} /* Release */,
\t\t\t);
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
''')
w('/* End XCConfigurationList section */\n\n/* Begin XCLocalSwiftPackageReference section */\n')
w(f'\t\t{pkgRef} /* XCLocalSwiftPackageReference "Packages/SpinCore" */ = {{\n\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = Packages/SpinCore;\n\t\t}};\n')
w('/* End XCLocalSwiftPackageReference section */\n\n/* Begin XCSwiftPackageProductDependency section */\n')
w(f'\t\t{pkgDep} /* SpinCore */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = SpinCore;\n\t\t}};\n')
w('/* End XCSwiftPackageProductDependency section */\n')
w(f'\t}};\n\trootObject = {proj} /* Project object */;\n}}\n')
os.makedirs(os.path.join(root, 'Pongo.xcodeproj/xcshareddata/xcschemes'), exist_ok=True)
os.makedirs(os.path.join(root, 'Pongo.xcodeproj/project.xcworkspace/xcshareddata'), exist_ok=True)
open(os.path.join(root, 'Pongo.xcodeproj/project.pbxproj'), 'w').write(''.join(out))
open(os.path.join(root, 'Pongo.xcodeproj/project.xcworkspace/contents.xcworkspacedata'), 'w').write('''<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
''')
open(os.path.join(root, 'Pongo.xcodeproj/xcshareddata/xcschemes/Pongo.xcscheme'), 'w').write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1500"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "Pongo.app"
               BlueprintName = "Pongo"
               ReferencedContainer = "container:Pongo.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "Pongo.app"
            BlueprintName = "Pongo"
            ReferencedContainer = "container:Pongo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "Pongo.app"
            BlueprintName = "Pongo"
            ReferencedContainer = "container:Pongo.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
''')
print(len(swift_files), 'swift files')
