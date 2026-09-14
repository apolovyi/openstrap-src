#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! developer_dir=$(xcode-select -p); then
  printf '[test-accessory-setup] Xcode is not selected. Select an installed Xcode with xcode-select before running this test.\n' >&2
  exit 1
fi
platform_dir="$developer_dir/Platforms/MacOSX.platform/Developer"
mkdir -p .tmp/accessory-setup-tests
if ! xcrun swiftc \
  -I "$platform_dir/usr/lib" \
  -F "$platform_dir/Library/Frameworks" \
  -L "$platform_dir/usr/lib" \
  -Xlinker -rpath -Xlinker "$platform_dir/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$platform_dir/Library/PrivateFrameworks" \
  -Xlinker -rpath -Xlinker "$platform_dir/usr/lib" \
  ios/Runner/AccessorySetup.swift test/native/accessory_setup_test.swift \
  -o .tmp/accessory-setup-tests/run; then
  printf '[test-accessory-setup] Native tests did not compile. Fix the compiler errors above and rerun bash tool/test_accessory_setup.sh.\n' >&2
  exit 1
fi
if ! .tmp/accessory-setup-tests/run; then
  printf '[test-accessory-setup] Native pairing regression tests failed. Inspect the failed assertions above and rerun bash tool/test_accessory_setup.sh.\n' >&2
  exit 1
fi
