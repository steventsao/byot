#!/usr/bin/env python3
"""Reject exported IPAs whose localized permission prompts override real copy."""

import plistlib
import re
import sys
import zipfile


def verify(ipa_path):
    with zipfile.ZipFile(ipa_path) as ipa:
        info_paths = [name for name in ipa.namelist()
                      if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(info_paths) != 1:
            raise ValueError("Expected one top-level app Info.plist")
        info_path = info_paths[0]
        root = info_path.removesuffix("Info.plist")
        info = plistlib.loads(ipa.read(info_path))
        keys = [key for key in info if key.endswith("UsageDescription")]
        for key in keys:
            check_description(key, info[key], "Info.plist")
        tables = [name for name in ipa.namelist()
                  if name.startswith(root) and re.fullmatch(
                      r"[^/]+\.lproj/InfoPlist\.strings", name[len(root):])]
        english_path = root + "en.lproj/InfoPlist.strings"
        if keys and english_path not in tables:
            raise ValueError("Missing English permission localization")
        for path in tables:
            table = plistlib.loads(ipa.read(path))
            for key in keys:
                check_description(key, table.get(key), path)
                if path == english_path and table[key] != info[key]:
                    raise ValueError(f"English permission differs from Info.plist: {key}")
        print(f"Permission descriptions verified: {len(keys)} keys, {len(tables)} languages.")


def check_description(key, value, location):
    if not isinstance(value, str) or not value.strip() or "UsageDescription" in value:
        raise ValueError(f"Missing or placeholder permission description: {location}: {key}")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("Usage: verify-permission-strings.py APP.ipa")
        verify(sys.argv[1])
    except (ValueError, OSError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        sys.exit(str(error))
