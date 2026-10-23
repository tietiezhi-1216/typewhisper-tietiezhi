#!/usr/bin/env python3
"""Build portable plugin + framework-dependent Windows x64 installer. No credentials required."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

root = Path(__file__).resolve().parent
repo = root.parent
dotnet = os.environ.get("DOTNET", "dotnet")
version = json.loads((root / "Tietiezhi/manifest.json").read_text())["version"]
dist = root / "dist"
dist.mkdir(exist_ok=True)

def run(*args):
    subprocess.run([dotnet, *map(str, args)], check=True, cwd=root)

def archive(source, output):
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as z:
        for file in sorted(source.rglob("*")):
            if file.is_file():
                z.write(file, file.relative_to(source))
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_name(output.name + ".sha256").write_text(digest + "  " + output.name + "\n")
    print(output)

run("build", root / "Tietiezhi/Tietiezhi.csproj", "-c", "Release", "--nologo")
staging = dist / "staging"
if staging.exists():
    shutil.rmtree(staging)
plugin = staging / "plugin"
plugin.mkdir(parents=True)
binary = root / "Tietiezhi/bin/Release/net10.0"
for name in ["TypeWhisper.Plugin.Tietiezhi.dll", "TypeWhisper.Plugin.Tietiezhi.deps.json", "manifest.json"]:
    shutil.copy2(binary / name, plugin / name)
for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
    shutil.copy2(repo / name, plugin / name)
(plugin / "SHA256SUMS").write_text("".join(
    hashlib.sha256(f.read_bytes()).hexdigest() + "  " + f.name + "\n"
    for f in sorted(plugin.iterdir()) if f.is_file()
))
assert not (plugin / "TypeWhisper.PluginSDK.dll").exists()
archive(plugin, dist / f"tietiezhi-{version}-windows-plugin.zip")
installer = staging / "installer"
run("publish", root / "Installer/Installer.csproj", "-c", "Release", "-r", "win-x64", "--self-contained", "false", "-o", installer, "--nologo")
for pdb in installer.glob("*.pdb"):
    pdb.unlink()
shutil.copytree(plugin, installer / "plugin")
shutil.copy2(root / "README.md", installer / "README.md")
archive(installer, dist / f"tietiezhi-{version}-windows-x64.zip")
