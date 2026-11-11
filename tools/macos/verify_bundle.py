#!/usr/bin/env python3
"""Check native Mach-O dependencies in a deployed Fritzing app."""

import argparse
import re
import subprocess
from pathlib import Path


def inspect(*arguments):
    return subprocess.check_output(arguments, text=True)


def binaries(bundle):
    for path in bundle.rglob("*"):
        if path.is_file() and not path.is_symlink():
            if "Mach-O" in inspect("file", "-b", str(path)):
                yield path


def rpaths(binary):
    commands = inspect("otool", "-arch", "arm64", "-l", str(binary))
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset", commands)


def verify(bundle, strip_build_rpaths):
    executable_dir = bundle / "Contents/MacOS"
    executable = executable_dir / "Fritzing"
    framework_dir = bundle / "Contents/Frameworks"
    if inspect("lipo", "-archs", str(executable)).strip() != "arm64":
        raise ValueError(f"Expected an arm64-only Fritzing executable: {executable}")

    files = list(binaries(bundle / "Contents/Frameworks"))
    files.extend(binaries(bundle / "Contents/PlugIns"))
    files.append(executable)
    for binary in files:
        for rpath in rpaths(binary):
            if rpath.startswith("@"):
                continue
            if not strip_build_rpaths or not rpath.startswith("/"):
                raise ValueError(f"{binary}: unexpected runpath {rpath}")
            subprocess.run(["install_name_tool", "-delete_rpath", rpath, str(binary)], check=True)

        libraries = inspect("otool", "-arch", "arm64", "-L", str(binary))
        for dependency in re.findall(r"^\s+(.+?) \(compatibility version", libraries, re.M):
            if dependency.startswith(("/System/Library/", "/usr/lib/")):
                continue
            roots = {
                "@rpath/": framework_dir,
                "@loader_path/": binary.parent,
                "@executable_path/": executable_dir,
            }
            for prefix, directory in roots.items():
                if dependency.startswith(prefix):
                    target = (directory / dependency[len(prefix):]).resolve()
                    if target.is_relative_to(bundle) and target.is_file():
                        break
            else:
                raise ValueError(f"{binary}: unresolved dependency {dependency}")

    print(f"Verified arm64 dependencies in {len(files)} Mach-O files")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--strip-build-rpaths", action="store_true")
    options = parser.parse_args()
    verify(options.app.resolve(), options.strip_build_rpaths)
