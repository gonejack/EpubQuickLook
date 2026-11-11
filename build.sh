#!/bin/bash
# EPUB Quick Look build script
#
#   ./build.sh            Build only (build/EPUB Quick Look.app)
#   ./build.sh install    Build, install to ~/Applications, and refresh the Quick Look cache
#   ./build.sh uninstall  Remove the installed app
#
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
BUILD="$ROOT/build"
APP_NAME="EPUB Quick Look"
APP="$BUILD/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
DEPLOY_TARGET="13.0"
ARCHS=("arm64" "x86_64")

SDK="$(xcrun --show-sdk-path --sdk macosx)"
SWIFTC="$(xcrun --find swiftc)"

KIT_SOURCES=("$ROOT"/Sources/EPUBKit/*.swift)

uninstall() {
	echo "==> Uninstalling"
	rm -rf "$INSTALL_DIR/$APP_NAME.app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
	qlmanage -r >/dev/null 2>&1 || true
	qlmanage -r cache >/dev/null 2>&1 || true
	echo "Done."
}

if [[ "${1:-}" == "uninstall" ]]; then
	uninstall
	exit 0
fi

# $1: Output executable path
# $2: Additional linker arguments (empty or the extension entry point)
# Remaining arguments: Source files and -framework arguments
compile() {
	local output="$1"; shift
	local extra_link="$1"; shift
	local thin=()

	for arch in "${ARCHS[@]}"; do
		local out="$BUILD/obj/$(basename "$output").$arch"
		mkdir -p "$(dirname "$out")"
		# shellcheck disable=SC2086
		"$SWIFTC" \
			-sdk "$SDK" \
			-target "$arch-apple-macos$DEPLOY_TARGET" \
			-O -wmo -swift-version 5 \
			$extra_link \
			"$@" \
			-o "$out"
		thin+=("$out")
	done

	mkdir -p "$(dirname "$output")"
	lipo -create "${thin[@]}" -output "$output"
	strip -x "$output" 2>/dev/null || true
}

echo "==> Cleaning previous build"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns"

echo "==> Building host app"
compile "$APP/Contents/MacOS/EPUBQuickLook" "" \
	"${KIT_SOURCES[@]}" "$ROOT/Sources/App/main.swift" \
	-framework Cocoa -framework WebKit -framework UniformTypeIdentifiers

echo "==> Building preview extension"
PREVIEW="$APP/Contents/PlugIns/EPUBPreviewExtension.appex"
mkdir -p "$PREVIEW/Contents/MacOS"
compile "$PREVIEW/Contents/MacOS/EPUBPreviewExtension" \
	"-Xlinker -e -Xlinker _NSExtensionMain -parse-as-library" \
	"${KIT_SOURCES[@]}" "$ROOT"/Sources/PreviewExtension/*.swift \
	-framework Cocoa -framework WebKit -framework Quartz

echo "==> Building thumbnail extension"
THUMB="$APP/Contents/PlugIns/EPUBThumbnailExtension.appex"
mkdir -p "$THUMB/Contents/MacOS"
compile "$THUMB/Contents/MacOS/EPUBThumbnailExtension" \
	"-Xlinker -e -Xlinker _NSExtensionMain -parse-as-library" \
	"${KIT_SOURCES[@]}" "$ROOT"/Sources/ThumbnailExtension/*.swift \
	-framework Cocoa -framework QuickLookThumbnailing

echo "==> Assembling app bundle"
cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Preview-Info.plist" "$PREVIEW/Contents/Info.plist"
cp "$ROOT/Resources/Thumbnail-Info.plist" "$THUMB/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
rm -rf "$BUILD/obj"

echo "==> Signing code (ad-hoc)"
codesign --force --sign - --timestamp=none \
	--entitlements "$ROOT/Resources/Extension.entitlements" "$PREVIEW"
codesign --force --sign - --timestamp=none \
	--entitlements "$ROOT/Resources/Extension.entitlements" "$THUMB"
codesign --force --sign - --timestamp=none \
	--entitlements "$ROOT/Resources/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "Build complete: $APP"

if [[ "${1:-}" == "install" ]]; then
	echo "==> Installing to $INSTALL_DIR"
	mkdir -p "$INSTALL_DIR"
	rm -rf "$INSTALL_DIR/$APP_NAME.app"
	cp -R "$APP" "$INSTALL_DIR/"

	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-f "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
	pluginkit -a "$INSTALL_DIR/$APP_NAME.app/Contents/PlugIns/EPUBPreviewExtension.appex" >/dev/null 2>&1 || true
	pluginkit -a "$INSTALL_DIR/$APP_NAME.app/Contents/PlugIns/EPUBThumbnailExtension.appex" >/dev/null 2>&1 || true
	qlmanage -r >/dev/null 2>&1 || true
	qlmanage -r cache >/dev/null 2>&1 || true
	killall Finder >/dev/null 2>&1 || true

	echo "Installation complete. Select an .epub file in Finder and press the space bar."
	echo "Check registration: pluginkit -m -p com.apple.quicklook.preview | grep -i epub"
fi
