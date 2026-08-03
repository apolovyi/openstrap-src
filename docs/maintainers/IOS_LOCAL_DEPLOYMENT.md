# Local iOS Deployment

Reusable procedure only. Keep personal values in ignored
`docs/local/ios-deployment.md`.

## Rules

- Use the Flutter version pinned in `.github/workflows/build.yml`.
- Use `ios/Runner.xcworkspace`, never the Xcode project.
- Keep personal signing in ignored `ios/Config/Signing.xcconfig`.
- Set `COCOAPODS_PARALLEL_CODE_SIGN=false`.
- FlutterFire is unnecessary unless using a real Firebase project or uploading symbols.

## Prepare

```bash
git status --short --branch
test -f .env || cp .env.example .env
test -f ios/Config/Signing.xcconfig || \
  cp ios/Config/Signing.xcconfig.example ios/Config/Signing.xcconfig

FLUTTER=/absolute/path/to/the/ci-pinned/flutter
"$FLUTTER" --version
"$FLUTTER" pub get
(cd ios && pod install)
"$FLUTTER" analyze
"$FLUTTER" test --concurrency=1
"$FLUTTER" build ios --release --no-codesign --dart-define-from-file=.env
```

Inspect `ios/Podfile.lock`. Restore changes that only update the CocoaPods generator
version; do not discard dependency changes.

## Confirm signing and device

```bash
security find-identity -v -p codesigning
xcrun devicectl list devices
xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'id=<DEVICE-UDID>' \
  COCOAPODS_PARALLEL_CODE_SIGN=false \
  -showBuildSettings
```

Confirm the team, app/widget/Watch bundle IDs, and App Group match
`ios/Config/Signing.xcconfig`. Record both the Xcode device UDID and CoreDevice ID.

## Build

```bash
xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  -destination 'id=<DEVICE-UDID>' \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  COCOAPODS_PARALLEL_CODE_SIGN=false \
  clean build
```

### Repeated keychain dialogs

Stop the build. Confirm the cause:

```bash
log show --style compact --last 5m \
  --predicate 'process == "securityd"' | \
  grep 'ACL partition mismatch'
```

Preserve existing key partitions and add `apple-tool:`, `apple:`, and `codesign:` to the
exact Apple Development private key. Never update every key. Read the password without
writing it to shell history:

```bash
IFS= read -r -s -p 'Mac login password: ' keychain_password
printf '\n'
security set-key-partition-list \
  -S 'apple-tool:,apple:,codesign:,<PRESERVED-EXISTING-PARTITIONS>' \
  -s -t private \
  -l '<EXACT-APPLE-DEVELOPMENT-PRIVATE-KEY-LABEL>' \
  -k "$keychain_password" \
  "$HOME/Library/Keychains/login.keychain-db"
unset keychain_password
```

Verify one disposable signature before rebuilding.

## Verify and deploy

Set `APP_PATH` to the built `Release-iphoneos/Runner.app`:

```bash
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
xcrun devicectl device install app --device <COREDEVICE-ID> "$APP_PATH"
xcrun devicectl device process launch \
  --device <COREDEVICE-ID> \
  <APP-BUNDLE-ID>
```

If iOS rejects the first launch, trust the developer under Settings → General → VPN &
Device Management, then launch again.

A successful launch does not prove BLE sync, HealthKit, widget/App Group flow, background
execution, or Watch launch. Record those separately.

## Finish

```bash
git diff -- ios/Podfile.lock
git status --short --branch
```

Keep `ios/Pods/Manifest.lock` synchronized with the restored lockfile. Update
`docs/local/ios-deployment.md` with the deployed commit, profile expiry, result, and gaps.
