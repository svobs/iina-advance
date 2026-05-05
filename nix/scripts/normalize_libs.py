#!/usr/bin/env python3
import sys
"""
normalize_libs.py

A script to collect IINA's libs & their transitive libs, then consolidate similar versions & normalize their paths for
use in the app bundle. This is needed to avoid multiple versions of the same lib being bundled, which is more difficult
to integrate into Xcode builds. Fixing the rpaths is also needed to replace hard-coded paths to the nix store with
relative paths within the app bundle.

_Pseudocode_:
let nameVariantsMap = [base_id -> [nameVariant -> fullVariantPath]]
let canonicalNameMap = [base_id -> canonicalName]
For all deps, build nameVariantsMap:
1. Find base_id from dep
2. Add to nameVariantsMap

For all entries in nameVariantsMap, build canonicalNameMap:
1. For each base_id, determine best canonicalName:
   Use most specific version available: split by dots. Verify that no major differences in vesions found!
2. Store best variant name in canonicalNameMap
3. Copy best variant to frameworksStaging

For all files in frameworksStaging:
1. Fix nixpath rpaths. Need to extract base_id for each & rewrite to use best variant! 
2. Fix any other rpaths needed
"""

def main():
  if len(sys.argv) < 3:
    print("usage: iina-normalize-app /path/to/IINA.app /path/to/IINA.app/ContentsFrameworks")
    exit(1)

    app_path = sys.argv[1]
    frameworks_path = sys.argv[2]
    
    print(f"Normalizing libs for appPath={app_path}, frameworksPath={frameworks_path}")

if __name__ == "__main__":
    main()
