#!/usr/bin/env python3
"""Build a clean SwiftPM consumer of an exact published, annotated PechPech tag."""

import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "https://github.com/arashparnia/pechpech.git"


def output(*command: str, cwd: Path = ROOT) -> str:
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="Published annotated tag, for example v1.0.0")
    options = parser.parse_args()
    if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", options.tag):
        parser.error("Expected a vMAJOR.MINOR.PATCH release tag")
    expected = output("git", "rev-parse", "HEAD")
    remote = output("git", "ls-remote", "--exit-code", REPOSITORY, f"refs/tags/{options.tag}^{{}}")
    if remote.split()[0] != expected:
        raise SystemExit("Published annotated tag does not resolve to the reviewed checkout commit")

    with tempfile.TemporaryDirectory(prefix="pechpech-release-consumer-") as directory:
        consumer = Path(directory)
        (consumer / "Package.swift").write_text(
            '// swift-tools-version: 6.1\nimport PackageDescription\n'
            'let package = Package(name: "PechPechReleaseConsumer", '
            'platforms: [.macOS(.v13), .iOS(.v16)], '
            f'dependencies: [.package(url: "{REPOSITORY}", exact: "{options.tag[1:]}")], '
            'targets: [.executableTarget(name: "ReleaseConsumer", dependencies: ['
            '.product(name: "PechPechCore", package: "pechpech"), '
            '.product(name: "PechPechApple", package: "pechpech")])])\n', encoding="utf-8")
        source = consumer / "Sources" / "ReleaseConsumer"
        source.mkdir(parents=True)
        shutil.copyfile(ROOT / "Examples/PackageConsumer/Sources/PackageConsumer/main.swift", source / "main.swift")
        subprocess.run(["swift", "build", "-c", "release"], cwd=consumer, check=True)
        resolved = json.loads((consumer / "Package.resolved").read_text(encoding="utf-8"))
        pins = [pin for pin in resolved["pins"] if pin["identity"] == "pechpech"]
        if len(pins) != 1 or pins[0]["state"]["revision"] != expected:
            raise SystemExit("SwiftPM did not resolve the exact reviewed release commit")
        products = output("swift", "build", "-c", "release", "--show-bin-path", cwd=consumer)
        subprocess.run(["python3", str(ROOT / "scripts/check-package-resources.py"),
                        "--products-dir", products], check=True)
    print(f"PASS: clean public consumer resolves {options.tag} to {expected}, builds both products, and retains their resources.")


if __name__ == "__main__":
    main()
