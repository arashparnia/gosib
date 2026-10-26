#!/usr/bin/env python3
"""Run portable SDK tests on Linux using isolated, development-only module shims.

Apple radio, Keychain and background execution are not exercised. The shipping
SwiftPM manifest and Apple cryptographic backend are left unchanged.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--swift", default="swift", help="Swift executable (5.10 or later)")
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--mock-bluetooth", action="store_true",
                        help="Execute the BLE adapter against a development-only CoreBluetooth mock")
    parser.add_argument("--filter", help="Optional XCTest filter")
    options = parser.parse_args()
    if sys.platform != "linux":
        parser.error("This development-only qualification harness is restricted to Linux")
    if options.jobs < 1:
        parser.error("--jobs must be positive")
    variant = "mock-bluetooth" if options.mock_bluetooth else "package"
    package = ROOT / ".build/linux-qualification" / variant
    package.mkdir(parents=True, exist_ok=True)
    for name in ("Sources", "Tests"):
        destination = package / name
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(ROOT / name, destination)
    crypto = package / "Shims/CryptoKit"
    crypto.mkdir(parents=True, exist_ok=True)
    (crypto / "CryptoKit.swift").write_text("@_exported import Crypto\n", encoding="utf-8")
    sqlite = package / "Shims/SQLite3"
    sqlite.mkdir(parents=True, exist_ok=True)
    (sqlite / "module.modulemap").write_text(
        'module SQLite3 [system] { header "shim.h" link "sqlite3" export * }\n', encoding="utf-8")
    (sqlite / "shim.h").write_text("#include <sqlite3.h>\n", encoding="utf-8")
    mock_target = ""
    mock_dependencies = ""
    mock_test_settings = ""
    mock = package / "Shims/CoreBluetooth"
    if mock.exists():
        shutil.rmtree(mock)
    if options.mock_bluetooth:
        shutil.copytree(ROOT / "scripts/linux/CoreBluetooth", mock)
        mock_target = '.target(name: "CoreBluetooth", path: "Shims/CoreBluetooth"),'
        mock_dependencies = ', "CoreBluetooth"'
        mock_test_settings = ', swiftSettings: [.define("PECHPECH_MOCK_BLUETOOTH")]'
    manifest = '''// swift-tools-version: 5.10
import PackageDescription
let package = Package(name: "PechPechLinuxQualification", dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "3.15.1"),
    .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.3.0")
], targets: [
    .systemLibrary(name: "SQLite3", path: "Shims/SQLite3", pkgConfig: "sqlite3"),
    .target(name: "CryptoKit", dependencies: [.product(name: "Crypto", package: "swift-crypto")], path: "Shims/CryptoKit"),
    MOCK_TARGET
    .target(name: "PechPechCore", dependencies: ["CryptoKit", "SQLite3"], resources: [.process("Resources")]),
    .target(name: "PechPechApple", dependencies: ["PechPechCore", "CryptoKit"MOCK_DEPENDENCIES], resources: [.process("Resources")]),
    .executableTarget(name: "PechPechDemo", dependencies: ["PechPechCore", "PechPechApple"]),
    .executableTarget(name: "PechPechProcessCrashProbe", dependencies: ["PechPechCore"], path: "Tests/ProcessCrashProbe"),
    .testTarget(name: "PechPechCoreTests", dependencies: ["PechPechCore", "CryptoKit", "SQLite3"], resources: [.copy("Fixtures")]),
    .testTarget(name: "PechPechAppleTests", dependencies: ["PechPechApple", "PechPechCore", "CryptoKit"MOCK_DEPENDENCIES]MOCK_TEST_SETTINGS)
], swiftLanguageVersions: [.v5])
'''
    (package / "Package.swift").write_text(
        manifest.replace("MOCK_TARGET", mock_target).replace("MOCK_DEPENDENCIES", mock_dependencies)
        .replace("MOCK_TEST_SETTINGS", mock_test_settings), encoding="utf-8")
    command = [options.swift, "test", "--package-path", str(package), "--jobs", str(options.jobs),
               "--configuration", options.configuration]
    if options.filter:
        command.extend(["--filter", options.filter])
    subprocess.run(command, cwd=ROOT, check=True)
    if not options.filter:
        subprocess.run([options.swift, "build", "--package-path", str(package), "--jobs", str(options.jobs),
                        "--configuration", options.configuration,
                        "--product", "PechPechProcessCrashProbe"], cwd=ROOT, check=True)
        products = subprocess.check_output(
            [options.swift, "build", "--package-path", str(package), "--configuration", options.configuration,
             "--show-bin-path"], cwd=ROOT, text=True).strip()
        subprocess.run(["python3", str(ROOT / "scripts/check-process-crash.py"), "--probe",
                        str(Path(products) / "PechPechProcessCrashProbe")], cwd=ROOT, check=True)
    resolved = json.loads((package / "Package.resolved").read_text(encoding="utf-8"))
    print("PASS: Linux portable qualification with development-only crypto/SQLite shims.")
    print("Dependency revisions:", json.dumps(resolved["pins"], sort_keys=True))
    if options.mock_bluetooth:
        print("BLE adapter paths executed against a development-only mock, not Apple's CoreBluetooth SDK.")
    print("Apple radio, Keychain, native Apple SDK compilation and OS background behavior were not tested.")


if __name__ == "__main__":
    main()
