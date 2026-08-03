# Local iOS Deployment Runbook

This runbook supplements `guides/IOS_INSTALLATION.md` for maintainers who build and
deploy from source. It records the procedure; put machine-specific values in the
ignored `docs/local/ios-deployment.md`.

## Sources of truth

- Flutter version: `.github/workflows/build.yml`; use the exact pinned version.
- App version: `pubspec.yaml`.
- Public signing defaults: `ios/Config/Signing.defaults.xcconfig`.
- Personal signing values: ignored `ios/Config/Signing.xcconfig`.
- Local environment: ignored `.env`.
- Local deployment state: ignored `docs/local/ios-deployment.md`.

Never commit Apple account names, team IDs, certificate hashes, profile UUIDs, device
identifiers, absolute local paths, or personal bundle identifiers.

## 1. Prepare and validate

Start from a clean checkout and use the workspace, not the Xcode project.

```bash
git status --short --branch
test -f .env || cp .env.example .env
test -f ios/Config/Signing.xcconfig || \
  cp ios/Config/Signing.xcconfig.example ios/Config/Signing.xcconfig
```

Set `FLUTTER` to the absolute executable from the CI-pinned SDK, then verify the actual
toolchain before resolving dependencies:

```bash
FLUTTER=/absolute/path/to/the/ci-pinned/flutter
"$FLUTTER" --version
pod --version
xcodebuild -version
"$FLUTTER" pub get
(cd ios && pod install)
```

Inspect any `ios/Podfile.lock` diff. Do not retain a change that only records the local
CocoaPods generator version. Do not discard real dependency changes without analysis.

Run the repository checks before deployment:

```bash
"$FLUTTER" analyze
"$FLUTTER" test --concurrency=1
```

Prepare Flutter's generated iOS settings and prove the source builds independently of
signing:

```bash
"$FLUTTER" build ios --release --no-codesign --dart-define-from-file=.env
```

## 2. Confirm account, device, and resolved settings

Xcode must show the intended account and development team. The iPhone must be connected,
paired, and in Developer Mode.

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

Verify the resolved team, app bundle ID, widget bundle ID, Watch bundle ID, and App Group
against `ios/Config/Signing.xcconfig`. Record both the hardware UDID used by Xcode and the
CoreDevice identifier printed by `devicectl`; they are different identifiers.

## 3. Provision and build

Always disable CocoaPods parallel code signing. Without established private-key access,
parallel signing can create one keychain dialog per embedded framework.

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

Automatic provisioning should create profiles for Runner, the widget extension, and the
Watch app. Treat `** BUILD SUCCEEDED **` as build evidence only; installation and launch
are separate gates.

### Keychain authorization failure

If repeated `codesign wants to access key` dialogs appear, stop the build instead of
entering the password repeatedly. Confirm the cause first:

```bash
log show --style compact --last 5m \
  --predicate 'process == "securityd"' | \
  grep 'ACL partition mismatch'
```

`/usr/bin/codesign` requires the private key's `apple:` partition. Preserve the key's
existing partition list and add `apple-tool:`, `apple:`, and `codesign:`. Target only the
exact Apple Development private-key label; never update every key in the login keychain.
Use a hidden shell variable so the login-keychain password is not written to shell
history:

```bash
IFS= read -r -s -p 'Mac login password: ' keychain_password
printf '\n'
security set-key-partition-list \
  -S 'apple-tool:,apple:,codesign:,<PRESERVED-EXISTING-PARTITIONS>' \
  -s \
  -t private \
  -l '<EXACT-APPLE-DEVELOPMENT-PRIVATE-KEY-LABEL>' \
  -k "$keychain_password" \
  "$HOME/Library/Keychains/login.keychain-db"
unset keychain_password
```

Verify with one disposable signature before another full build. If terminated signing
clients leave dialogs behind, confirm no relevant `codesign` process remains before
restarting the user-scoped `SecurityAgent`; do not restart system authentication daemons.

## 4. Verify, install, and launch

Take `APP_PATH` from the successful build's `Build/Products/Release-iphoneos/Runner.app`
path. Verify all nested signatures before installation:

```bash
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

Use the CoreDevice identifier from `xcrun devicectl list devices`:

```bash
xcrun devicectl device install app \
  --device <COREDEVICE-ID> \
  "$APP_PATH"

xcrun devicectl device process launch \
  --device <COREDEVICE-ID> \
  <APP-BUNDLE-ID>
```

A successful install is not a successful deployment until `devicectl` reports that it
launched the bundle. On first install, iOS can require explicit developer trust under
Settings → General → VPN & Device Management; complete that step and launch again.

Also verify the embedded app, widget, and Watch `Info.plist` bundle IDs and versions, and
decode each `embedded.mobileprovision` when diagnosing an entitlement or device mismatch.
The profile must include the target device and the signed entitlements must be allowed by
the profile.

Record manual gaps separately. A command-line launch does not prove BLE pairing, HealthKit
exchange, widget/App Group data flow, permission prompts, background execution, or Watch
launch.

## 5. Firebase tooling

FlutterFire CLI is not required for the default local build. Firebase initialization is
optional in `lib/main.dart`, local native configuration is inert when no real Firebase
files are supplied, and the Crashlytics symbol-upload build phase is nonfatal. CI pins and
installs FlutterFire CLI because release jobs mount real Firebase secrets.

Install FlutterFire CLI only when configuring a real Firebase project or intentionally
uploading symbols. Do not run `flutterfire configure` against the default local build.

## 6. Clean up

Keep generated output and machine state untracked:

```bash
git diff -- ios/Podfile.lock
git status --short --branch
```

Restore generator-only lockfile drift after confirming dependency content is unchanged.
Keep `ios/Pods/Manifest.lock` synchronized with the restored canonical lockfile. Update
`docs/local/ios-deployment.md` with the deployed source commit, artifact, profile expiry,
verification result, and remaining manual gaps.
