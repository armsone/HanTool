#!/usr/bin/env python3
"""
Development and build helper for HTD macOS.
Usage:
  /usr/bin/python3 scripts/dev.py build              (development engine fallback only)
  /usr/bin/python3 scripts/dev.py build --portable   (also copies the built portable engine; build it first with
                                                      scripts/build_portable_engine.py, it is never frozen from here)
"""

import sys
import os
import shutil
import subprocess
import json
import plistlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

def run_cmd(cmd, cwd=ROOT):
    print(f"==> Running: {' '.join(cmd)}")
    res = subprocess.run(cmd, cwd=cwd)
    if res.returncode != 0:
        print(f"Error: command failed with exit code {res.returncode}", file=sys.stderr)
        sys.exit(res.returncode)

def check_portable_artifact():
    """The portable runtime must match the current engine sources before anything is built or copied."""
    sys.path.insert(0, HERE)
    import build_portable_engine
    problems = build_portable_engine.verify_artifact()
    if not problems:
        with open(os.path.join(ROOT, "Resources", "Info.plist"), "rb") as f:
            app_minimum = plistlib.load(f)["LSMinimumSystemVersion"]
        with open(os.path.join(build_portable_engine.RUNTIME_DIR, build_portable_engine.MANIFEST_NAME), encoding="utf-8") as f:
            runtime_minimum = json.load(f)["machoMaxMinOS"]
        if build_portable_engine.version_tuple(runtime_minimum) > build_portable_engine.version_tuple(app_minimum):
            problems.append(f"engine requires macOS {runtime_minimum}, but the app declares {app_minimum}")
    if problems:
        print("Error: portable engine artifact is not usable:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print("Build it first: <venv>/bin/python scripts/build_portable_engine.py", file=sys.stderr)
        sys.exit(1)
    return build_portable_engine.RUNTIME_DIR

def build(portable=False):
    print(f"Building HTD in {ROOT}...")
    portable_runtime = check_portable_artifact() if portable else None

    # Ensure local build & module cache directories exist inside workspace
    build_dir = os.path.join(ROOT, ".build")
    release_dir = os.path.join(build_dir, "release")
    module_cache_dir = os.path.join(build_dir, "module-cache")
    clang_cache_dir = os.path.join(build_dir, "clang-module-cache")

    os.makedirs(release_dir, exist_ok=True)
    os.makedirs(module_cache_dir, exist_ok=True)
    os.makedirs(clang_cache_dir, exist_ok=True)

    # Set cache and temporary directories to local workspace / /tmp
    os.environ["TMPDIR"] = "/tmp"
    os.environ["CLANG_MODULE_CACHE_PATH"] = clang_cache_dir
    os.environ["SWIFT_MODULE_CACHE_PATH"] = module_cache_dir

    swift_sources = [
        os.path.join(ROOT, "Sources", "HttpsDown", "HttpsDownApp.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "Models.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "BrowserPreferences.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "Publisher.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "EngineBridge.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AppModel.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "QueueActions.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "Views.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "ConnectionManager.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SessionManager.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SiteRoutes.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "LoginWindow.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "MediaDiscovery.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "BrowserHomeView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "BrowserView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "BrowserScreenshot.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "BrowserExtensions.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SpeedTestView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SupportedSitesView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "Appearance.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "URLDrop.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "Diagnostics.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "JobThumbnail.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "GoogleAutofill.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SiteCredentialStore.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SiteCredentialCapture.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "MouseGestures.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "YouTubeLink.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AutoShorts.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "PopupSitePermissions.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "NetworkRateIndicator.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AddressSearch.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AIService.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AIServiceSettingsView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AILoginStatusStore.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "HanaAddressCommand.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "HanaPanelLocation.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "HanaPanel.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AIPageContext.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "WebPageAgent.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "WebPageAgentTransport.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWCLITransport.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWCLIAccounts.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "WebPageAgentView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWProjects.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWToolModels.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWToolScope.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWToolRuntime.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWMCPStdioClient.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWToolSettingsView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWScheduler.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWWorkspace.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWTeam.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWExaSearch.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWHanaTeamAdapter.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWTeamBrowserWorker.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWTeamRuntime.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWTeamSettingsView.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWTeamHosts.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "PageAudioController.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWReport.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWReportContent.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "SAWAutomaticProvider.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AssistantPlannerBridge.swift"),
        os.path.join(ROOT, "Sources", "HttpsDown", "AssistantWebSession.swift"),
    ]

    dest_bin = os.path.join(release_dir, "HTD")
    swiftc_bin = shutil.which("swiftc") or "/usr/bin/swiftc"
    arch = "arm64" if os.uname().machine == "arm64" else "x86_64"
    target = f"{arch}-apple-macosx14.0"

    compile_cmd = [
        swiftc_bin,
        "-parse-as-library",
        "-target", target,
        "-swift-version", "5",
        "-O",
        "-module-cache-path", module_cache_dir,
        "-Xcc", f"-fmodules-cache-path={clang_cache_dir}",
        "-o", dest_bin,
    ] + swift_sources

    run_cmd(compile_cmd)

    if not os.path.isfile(dest_bin):
        print(f"Error: Output binary not found at {dest_bin}", file=sys.stderr)
        sys.exit(1)

    print(f"Successfully compiled binary: {dest_bin}")

    # Assemble app bundle
    dist_dir = os.path.join(ROOT, "dist")
    app_dir = os.path.join(dist_dir, "HTD.app")
    contents_dir = os.path.join(app_dir, "Contents")
    macos_dir = os.path.join(contents_dir, "MacOS")
    resources_dir = os.path.join(contents_dir, "Resources")

    if os.path.exists(app_dir):
        shutil.rmtree(app_dir)

    os.makedirs(macos_dir, exist_ok=True)
    os.makedirs(resources_dir, exist_ok=True)

    app_bin = os.path.join(macos_dir, "HTD")
    shutil.copy2(dest_bin, app_bin)
    os.chmod(app_bin, 0o755)

    info_plist_src = os.path.join(ROOT, "Resources", "Info.plist")
    if os.path.isfile(info_plist_src):
        shutil.copy2(info_plist_src, os.path.join(contents_dir, "Info.plist"))

    shutil.copy2(os.path.join(ROOT, "Resources", "AppIcon.icns"), os.path.join(resources_dir, "AppIcon.icns"))

    engine_src = os.path.join(ROOT, "Engine", "engine.py")
    if os.path.isfile(engine_src):
        dest_engine = os.path.join(resources_dir, "engine.py")
        shutil.copy2(engine_src, dest_engine)
        os.chmod(dest_engine, 0o755)

    # Helper modules imported by engine.py from its own directory.
    for module in ("connection.py", "session.py", "live.py", "mp4.py", "speed.py", "discovery.py", "keys.py", "keydecode.mjs", "fragments.py", "progressive.py"):
        module_src = os.path.join(ROOT, "Engine", module)
        if not os.path.isfile(module_src):
            print(f"Error: engine module missing: {module_src}", file=sys.stderr)
            sys.exit(1)
        module_dest = os.path.join(resources_dir, module)
        shutil.copy2(module_src, module_dest)
        os.chmod(module_dest, 0o644)

    # Browser video discovery script (injected into the in-app browser's isolated content world).
    js_src = os.path.join(ROOT, "Resources", "MediaDiscovery.js")
    if not os.path.isfile(js_src):
        print(f"Error: browser resource missing: {js_src}", file=sys.stderr)
        sys.exit(1)
    shutil.copy2(js_src, os.path.join(resources_dir, "MediaDiscovery.js"))
    os.chmod(os.path.join(resources_dir, "MediaDiscovery.js"), 0o644)

    # Mechanical public supported-sites & registered-extractors catalog.
    sites_src = os.path.join(ROOT, "Resources", "SupportedSites.json")
    if not os.path.isfile(sites_src):
        print(f"Error: supported sites resource missing: {sites_src}", file=sys.stderr)
        sys.exit(1)
    shutil.copy2(sites_src, os.path.join(resources_dir, "SupportedSites.json"))
    os.chmod(os.path.join(resources_dir, "SupportedSites.json"), 0o644)

    # AI browser runtime and provider catalog resources
    for ai_file in ("aibi-browser-runtime.js", "aibi-providers.json", "htt-web-agent-runtime.js"):
        ai_src = os.path.join(ROOT, "Sources", "HttpsDown", "AIResources", ai_file)
        if not os.path.isfile(ai_src):
            print(f"Error: AI resource missing: {ai_src}", file=sys.stderr)
            sys.exit(1)
        shutil.copy2(ai_src, os.path.join(resources_dir, ai_file))
        os.chmod(os.path.join(resources_dir, ai_file), 0o644)

    if portable_runtime:
        # Verified above against the current sources; copied as a whole tree (symlinks kept) before signing.
        shutil.copytree(portable_runtime, os.path.join(resources_dir, "EngineRuntime"), symlinks=True)
        notices_src = os.path.join(ROOT, "Resources", "THIRD-PARTY-NOTICES.txt")
        if not os.path.isfile(notices_src):
            print(f"Error: third-party notices missing: {notices_src}", file=sys.stderr)
            sys.exit(1)
        shutil.copy2(notices_src, os.path.join(resources_dir, "THIRD-PARTY-NOTICES.txt"))

    # Ad-hoc codesign for local development
    codesign_bin = shutil.which("codesign") or "/usr/bin/codesign"
    if portable:
        # No --deep: keeps the PyInstaller leaf signatures and hash manifest unchanged. Any failure fails the build.
        if not os.path.exists(codesign_bin):
            print("Error: codesign not found; cannot sign the portable app", file=sys.stderr)
            sys.exit(1)
        run_cmd([codesign_bin, "--force", "--sign", "-", app_dir])
    elif os.path.exists(codesign_bin):
        print("Applying ad-hoc code signature for local development...")
        res = subprocess.run([codesign_bin, "--force", "--deep", "--sign", "-", app_dir])
        if res.returncode != 0:
            print("Warning: codesign returned non-zero code, continuing...", file=sys.stderr)

    print(f"Successfully packaged: {app_dir}")
    record_build(app_dir, app_bin, dest_engine if os.path.isfile(engine_src) else None)

def sha256_of(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def record_build(app_dir, app_bin, engine_copy):
    """Record the exact bundle that was built so verification evidence can be tied to it."""
    import json
    import datetime
    verify = subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app_dir],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    info = {
        "built": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
        "bundle": os.path.relpath(app_dir, ROOT),
        "executable_sha256": sha256_of(app_bin),
        "executable_bytes": os.path.getsize(app_bin),
        "engine_py_sha256": sha256_of(engine_copy) if engine_copy else None,
        "engine_source_sha256": sha256_of(os.path.join(ROOT, "Engine", "engine.py")),
        "swift_sources_sha256": {
            n: sha256_of(os.path.join(ROOT, "Sources", "HttpsDown", n))
            for n in sorted(os.listdir(os.path.join(ROOT, "Sources", "HttpsDown"))) if n.endswith(".swift")
        },
        "codesign": "ad-hoc, verify exit %d" % verify.returncode,
        "portable_engine": os.path.isdir(os.path.join(app_dir, "Contents", "Resources", "EngineRuntime")),
    }
    evid = os.path.join(ROOT, "validation", "evidence")
    os.makedirs(evid, exist_ok=True)
    with open(os.path.join(evid, "build.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=2)
    report = os.path.join(ROOT, "docs", "verification.json")
    if os.path.isfile(report):
        try:
            with open(report, encoding="utf-8") as f:
                data = json.load(f)
            data["build"] = info
            with open(report, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False, indent=2)
        except ValueError:
            pass
    print(f"Recorded build evidence: executable sha256 {info['executable_sha256'][:16]}… ({info['codesign']})")

def main():
    extra = sys.argv[2:]
    if len(sys.argv) < 2 or sys.argv[1] != "build" or any(a != "--portable" for a in extra):
        print("Usage: /usr/bin/python3 scripts/dev.py build [--portable]", file=sys.stderr)
        sys.exit(1)
    build(portable="--portable" in extra)

if __name__ == "__main__":
    main()
