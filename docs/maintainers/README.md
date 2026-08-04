# Maintainer Runbooks

These documents cover repeatable repository maintenance. User-facing setup remains in
`guides/`.

- [`IOS_LOCAL_DEPLOYMENT.md`](IOS_LOCAL_DEPLOYMENT.md) — build, provision, sign,
  install, launch, verify, and clean up a local iOS deployment.
- [`WHOOP4_FIRMWARE_COMPATIBILITY.md`](WHOOP4_FIRMWARE_COMPATIBILITY.md) — evaluate
  firmware evidence and run a non-destructive pre/post-update verification.

Machine-specific state belongs in `docs/local/`, which is gitignored. For iOS,
maintain `docs/local/ios-deployment.md` with the current Mac, Apple team, bundle
identifiers, device identifiers, profile state, artifact path, deployed source commit,
and verification gaps. Never put those values in tracked documentation.
