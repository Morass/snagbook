#!/usr/bin/env python3
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
check_only = '--check' in sys.argv[2:]
accessors = list(root.glob('*.build/DerivedSources/resource_bundle_accessor.swift'))
if not accessors:
    raise SystemExit('SwiftPM resource accessors were not found')
for path in accessors:
    source = path.read_text()
    # SwiftPM emits a CLI lookup; a signed macOS app keeps these bundles in Resources.
    prepared = source.replace('Bundle.main.bundleURL.appendingPathComponent',
                              '(Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent')
    prepared = re.sub(r'(?m)^(\s*let buildPath\s*=).*$', r'\1 ""', prepared)
    if check_only:
        if source != prepared:
            raise SystemExit('Resource lookup is incompatible with the app bundle: ' + path.name)
    elif source != prepared:
        path.write_text(prepared)
print('App resource accessors verified' if check_only else 'App resource accessors prepared')
