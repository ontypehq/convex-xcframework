# convex-xcframework

Prebuilt Convex macOS `libconvexmobile-rs.xcframework` slices for OnType.

This repository publishes release artifacts so OnType builds do not need to
compile Convex Mobile Rust code during every app build.

## Artifact Contract

Release assets contain:

- `libconvexmobile-rs.xcframework/`
- `manifest.json`

The manifest records:

- `convexSwiftVersion`
- `convexSwiftRevision`
- `convexMobileRevision`
- `macosMinVersion`
- Xcode, Swift, Rust, and Cargo versions
- per-architecture SHA-256 and byte size for `libconvexmobile.a`

The artifact key is intentionally source-derived. Consumers should verify the
manifest before copying slices into a SwiftPM checkout.

