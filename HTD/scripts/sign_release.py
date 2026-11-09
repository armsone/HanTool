#!/usr/bin/env python3
"""
Developer ID signing of the portable HTD app (hardened runtime, secure timestamp). Nothing is notarized or uploaded here.

  /usr/bin/python3 scripts/sign_release.py --app dist/HTD.app --out-dir dist/release-0.14.3 --identity <SHA-1 or name>

Copies the ad-hoc built app, signs every nested Mach-O inside-out, rewrites the app's portable-manifest.json so its
recorded hashes describe the signed files (verify_artifact must pass on the result), then signs the app bundle.
The source app and the PyInstaller build folder are never modified.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import build_portable_engine as bpe  # noqa: E402

CODESIGN = "/usr/bin/codesign"

JIT_ENTITLEMENTS = {"com.apple.security.cs.allow-jit": True,
                    "com.apple.security.cs.allow-unsigned-executable-memory": True}
ENGINE_ENTITLEMENTS = {"com.apple.security.cs.disable-library-validation": True}


def run(cmd, check=True):
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
    if check and p.returncode != 0:
        bpe.fail(f"{' '.join(os.path.basename(c) for c in cmd[:2])} failed ({p.returncode}): {p.stdout.strip()[-600:]}")
    return p


def entitlements_for(path):
    name = os.path.basename(path)
    if name == "deno":
        return JIT_ENTITLEMENTS
    if name == bpe.ENGINE_NAME:
        return ENGINE_ENTITLEMENTS
    return None


def sign(path, identity, entitlements=None, tmp=None):
    cmd = [CODESIGN, "--force", "--timestamp", "--options", "runtime", "--sign", identity]
    if entitlements:
        import plistlib
        plist = os.path.join(tmp, os.path.basename(path) + ".entitlements.plist")
        with open(plist, "wb") as f:
            plistlib.dump(entitlements, f)
        cmd += ["--entitlements", plist]
    run(cmd + [path])


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--app", required=True)
    p.add_argument("--out-dir", required=True)
    p.add_argument("--identity", required=True)
    args = p.parse_args()

    out_dir = os.path.abspath(args.out_dir)
    if os.path.lexists(out_dir):
        bpe.fail("output folder already exists; pass a fresh --out-dir")
    os.makedirs(out_dir)
    app = os.path.join(out_dir, "HTD.app")
    run(["/usr/bin/ditto", args.app, app])
    runtime = os.path.join(app, "Contents", "Resources", "EngineRuntime")
    tmp = tempfile.mkdtemp(prefix="htd-sign-")
    try:
        machos = bpe.macho_files(runtime)
        # Deepest paths first so nothing is sealed before its contents are final.
        machos.sort(key=lambda x: (-x.count(os.sep), x))
        for path in machos:
            sign(path, args.identity, entitlements_for(path), tmp)
        print(f"==> signed {len(machos)} nested Mach-O files")

        manifest_path = os.path.join(runtime, bpe.MANIFEST_NAME)
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
        manifest["executableSha256"] = bpe.sha256_file(os.path.join(runtime, bpe.ENGINE_NAME))
        manifest["tools"] = {n: bpe.sha256_file(os.path.join(runtime, "_internal", "tools", n)) for n in bpe.TOOLS}
        files, size = bpe.tree_stats(runtime)
        manifest["files"], manifest["bytes"] = files, size
        manifest["signing"] = {"kind": "Developer ID Application", "hardenedRuntime": True,
                               "machoFilesSigned": len(machos),
                               "entitlements": {"deno": sorted(JIT_ENTITLEMENTS), "htd-engine": sorted(ENGINE_ENTITLEMENTS)}}
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=2, sort_keys=True)
            f.write("\n")
        problems = bpe.verify_artifact(runtime)
        if problems:
            bpe.fail("signed runtime does not match its manifest: " + "; ".join(problems))
        print("==> manifest updated and verified against the signed runtime")

        sign(app, args.identity)
        run([CODESIGN, "--verify", "--deep", "--strict", "--verbose=2", app])
        print(f"Signed app: {app}")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
