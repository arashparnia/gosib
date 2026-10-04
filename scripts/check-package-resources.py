#!/usr/bin/env python3
"""Validate source and compiled SwiftPM privacy/license resources, offline."""

import argparse
import plistlib
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
LIBRARIES = ("PechPechCore", "PechPechApple")
EXPECTED = {
    "NSPrivacyTracking": False,
    "NSPrivacyTrackingDomains": [],
    "NSPrivacyCollectedDataTypes": [],
    "NSPrivacyAccessedAPITypes": [],
}


def check_resources(manifest: Path, license_bytes: bytes) -> None:
    with manifest.open("rb") as source:
        declared = plistlib.load(source)
    if declared != EXPECTED or type(declared.get("NSPrivacyTracking")) is not bool:
        raise SystemExit(f"Unexpected SDK privacy declaration: {manifest}")
    notice = manifest.parent / "PechPech-LICENSE.txt"
    if not notice.is_file() or notice.read_bytes() != license_bytes:
        raise SystemExit(f"Missing or outdated complete MIT notice: {notice}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--products-dir", type=Path,
                        help="Built product directory; defaults to SwiftPM release bin path")
    options = parser.parse_args()
    license_bytes = (ROOT / "LICENSE").read_bytes()
    for library in LIBRARIES:
        check_resources(ROOT / "Sources" / library / "Resources" / "PrivacyInfo.xcprivacy",
                        license_bytes)
    products = options.products_dir
    if products is None:
        products = Path(subprocess.check_output(
            ["swift", "build", "-c", "release", "--show-bin-path"],
            cwd=ROOT, text=True).strip())
    if not products.is_dir():
        raise SystemExit(f"Build the package first; product directory is absent: {products}")
    manifests = list(products.rglob("PrivacyInfo.xcprivacy"))
    for library in LIBRARIES:
        matches = [path for path in manifests if library in str(path.relative_to(products))]
        if len(matches) != 1:
            raise SystemExit(f"Expected one built {library} privacy resource, found {len(matches)}")
        check_resources(matches[0], license_bytes)
    print("PASS: both compiled library bundles contain valid SDK privacy manifests and complete MIT notices.")


if __name__ == "__main__":
    main()
