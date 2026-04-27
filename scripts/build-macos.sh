#!/usr/bin/env bash
set -euo pipefail

CONVEX_SWIFT_VERSION="${CONVEX_SWIFT_VERSION:-0.8.1}"
CONVEX_MOBILE_REV="${CONVEX_MOBILE_REV:-59081a707f3b13a7d3268e028e41c55316c46996}"
MACOS_MIN_VERSION="${MACOS_MIN_VERSION:-15.0}"
ARCHES="${ARCHES:-arm64 x86_64}"
OUT_DIR="${1:-dist}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$repo_root/.scratch/build"
stage_dir="$work_dir/stage"
swift_pkg_dir="$work_dir/swift-package"
convex_mobile_dir="$work_dir/convex-mobile"
xcframework_dir="$stage_dir/libconvexmobile-rs.xcframework"

rm -rf "$work_dir"
mkdir -p "$stage_dir" "$swift_pkg_dir" "$OUT_DIR"

cat > "$swift_pkg_dir/Package.swift" <<SWIFT
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ConvexXcframeworkProbe",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/get-convex/convex-swift", exact: "$CONVEX_SWIFT_VERSION"),
    ],
    targets: [
        .executableTarget(
            name: "Probe",
            dependencies: [.product(name: "ConvexMobile", package: "convex-swift")]
        ),
    ]
)
SWIFT
mkdir -p "$swift_pkg_dir/Sources/Probe"
printf 'import ConvexMobile\nprint("probe")\n' > "$swift_pkg_dir/Sources/Probe/main.swift"

swift package --package-path "$swift_pkg_dir" resolve

source_xcframework="$(find "$swift_pkg_dir/.build/checkouts/convex-swift" -type d -name 'libconvexmobile-rs.xcframework' | head -n 1)"
if [[ -z "$source_xcframework" ]]; then
  echo "Unable to find libconvexmobile-rs.xcframework in convex-swift checkout." >&2
  exit 1
fi

convex_swift_revision="$(git -C "$swift_pkg_dir/.build/checkouts/convex-swift" rev-parse HEAD)"
headers_source="$(find "$source_xcframework" -path '*/Headers' -type d | head -n 1)"
if [[ -z "$headers_source" ]]; then
  echo "Unable to find Convex xcframework headers." >&2
  exit 1
fi

git clone --depth 1 https://github.com/get-convex/convex-mobile.git "$convex_mobile_dir"
git -C "$convex_mobile_dir" fetch --depth 1 origin "$CONVEX_MOBILE_REV"
git -C "$convex_mobile_dir" checkout "$CONVEX_MOBILE_REV"

sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
rust_dir="$convex_mobile_dir/rust"
manifest_entries=()

rust_target_for_arch() {
  case "$1" in
    arm64) echo "aarch64-apple-darwin" ;;
    x86_64) echo "x86_64-apple-darwin" ;;
    *) echo "unsupported arch: $1" >&2; exit 1 ;;
  esac
}

target_env_key() {
  printf '%s' "$1" | tr '[:lower:]-' '[:upper:]_'
}

validate_minos() {
  local archive="$1"
  local temp_dir
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' RETURN
  (cd "$temp_dir" && ar -x "$archive")
  while IFS= read -r object_file; do
    local minos
    minos="$(vtool -show-build "$object_file" 2>/dev/null | awk '/^[[:space:]]*minos[[:space:]]+/ {print $2; exit}')"
    if [[ -n "$minos" ]] && ! python3 - "$MACOS_MIN_VERSION" "$minos" <<'PY'
import sys
allowed = tuple(int(part) for part in sys.argv[1].split("."))
actual = tuple(int(part) for part in sys.argv[2].split("."))
width = max(len(allowed), len(actual))
allowed += (0,) * (width - len(allowed))
actual += (0,) * (width - len(actual))
sys.exit(0 if actual <= allowed else 1)
PY
    then
      echo "Archive object targets macOS $minos, newer than allowed $MACOS_MIN_VERSION: $object_file" >&2
      exit 1
    fi
  done < <(find "$temp_dir" -type f -name '*.o')
  rm -rf "$temp_dir"
  trap - RETURN
}

mkdir -p "$xcframework_dir"
for arch in $ARCHES; do
  rust_target="$(rust_target_for_arch "$arch")"
  env_key="$(target_env_key "$rust_target")"
  min_flag="-mmacosx-version-min=$MACOS_MIN_VERSION"

  rustup target add "$rust_target"
  rm -rf "$rust_dir/target/$rust_target"

  export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION"
  export SDKROOT="$sdk_root"
  export CFLAGS="${CFLAGS:-} $min_flag -isysroot $sdk_root"
  export CXXFLAGS="${CXXFLAGS:-} $min_flag -isysroot $sdk_root"
  rustflags_key="CARGO_TARGET_${env_key}_RUSTFLAGS"
  export "$rustflags_key=${!rustflags_key:-} -C link-arg=$min_flag -C link-arg=-isysroot -C link-arg=$sdk_root"

  cargo build --manifest-path "$rust_dir/Cargo.toml" --lib --release --target "$rust_target"
  built_lib="$rust_dir/target/$rust_target/release/libconvexmobile.a"
  validate_minos "$built_lib"

  slice_dir="$xcframework_dir/macos-$arch"
  mkdir -p "$slice_dir"
  cp "$built_lib" "$slice_dir/libconvexmobile.a"
  cp -R "$headers_source" "$slice_dir/Headers"

  bytes="$(wc -c < "$slice_dir/libconvexmobile.a" | tr -d ' ')"
  sha256="$(shasum -a 256 "$slice_dir/libconvexmobile.a" | awk '{print $1}')"
  manifest_entries+=("{\"arch\":\"$arch\",\"libraryIdentifier\":\"macos-$arch\",\"sha256\":\"$sha256\",\"bytes\":$bytes}")
done

available_libraries=""
for arch in $ARCHES; do
  available_libraries+="
    <dict>
      <key>BinaryPath</key>
      <string>libconvexmobile.a</string>
      <key>HeadersPath</key>
      <string>Headers</string>
      <key>LibraryIdentifier</key>
      <string>macos-$arch</string>
      <key>LibraryPath</key>
      <string>libconvexmobile.a</string>
      <key>SupportedArchitectures</key>
      <array>
        <string>$arch</string>
      </array>
      <key>SupportedPlatform</key>
      <string>macos</string>
    </dict>"
done

cat > "$xcframework_dir/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AvailableLibraries</key>
  <array>$available_libraries
  </array>
  <key>CFBundlePackageType</key>
  <string>XFWK</string>
  <key>XCFrameworkFormatVersion</key>
  <string>1.0</string>
</dict>
</plist>
PLIST

entries_json="$(IFS=,; echo "${manifest_entries[*]}")"
cat > "$stage_dir/manifest.json" <<JSON
{
  "version": 1,
  "artifact": "convex-xcframework-macos",
  "convexSwiftVersion": "$CONVEX_SWIFT_VERSION",
  "convexSwiftRevision": "$convex_swift_revision",
  "convexMobileRevision": "$CONVEX_MOBILE_REV",
  "macosMinVersion": "$MACOS_MIN_VERSION",
  "xcodeVersion": "$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')",
  "swiftVersion": "$(swift --version | head -n 1)",
  "rustVersion": "$(rustc --version)",
  "cargoVersion": "$(cargo --version)",
  "builtAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "slices": [$entries_json]
}
JSON

tag_suffix="${CONVEX_SWIFT_VERSION}-${CONVEX_MOBILE_REV:0:12}"
artifact_name="convex-xcframework-macos-$tag_suffix.tar.gz"
tar -czf "$OUT_DIR/$artifact_name" -C "$stage_dir" libconvexmobile-rs.xcframework manifest.json
shasum -a 256 "$OUT_DIR/$artifact_name" > "$OUT_DIR/$artifact_name.sha256"

echo "artifact=$OUT_DIR/$artifact_name"
