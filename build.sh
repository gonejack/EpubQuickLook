#!/bin/bash
# EPUB Quick Look 빌드 스크립트
#
#   ./build.sh            빌드만 수행 (build/EPUB Quick Look.app)
#   ./build.sh install    빌드 후 ~/Applications 에 설치하고 Quick Look 캐시를 갱신
#   ./build.sh uninstall  설치된 앱 제거
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
	echo "==> 설치 제거"
	rm -rf "$INSTALL_DIR/$APP_NAME.app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
		-kill -r -domain local -domain system -domain user >/dev/null 2>&1 || true
	qlmanage -r >/dev/null 2>&1 || true
	qlmanage -r cache >/dev/null 2>&1 || true
	echo "완료."
}

if [[ "${1:-}" == "uninstall" ]]; then
	uninstall
	exit 0
fi

# $1: 출력 실행 파일 경로
# $2: 추가 링커 인자 ("" 또는 확장 엔트리포인트)
# 나머지: 소스 파일과 -framework 인자
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

echo "==> 이전 빌드 정리"
rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns"

echo "==> 호스트 앱 빌드"
compile "$APP/Contents/MacOS/EPUBQuickLook" "" \
	"${KIT_SOURCES[@]}" "$ROOT/Sources/App/main.swift" \
	-framework Cocoa -framework WebKit -framework UniformTypeIdentifiers

echo "==> 미리보기 확장 빌드"
PREVIEW="$APP/Contents/PlugIns/EPUBPreviewExtension.appex"
mkdir -p "$PREVIEW/Contents/MacOS"
compile "$PREVIEW/Contents/MacOS/EPUBPreviewExtension" \
	"-Xlinker -e -Xlinker _NSExtensionMain -parse-as-library" \
	"${KIT_SOURCES[@]}" "$ROOT"/Sources/PreviewExtension/*.swift \
	-framework Cocoa -framework WebKit -framework Quartz

echo "==> 썸네일 확장 빌드"
THUMB="$APP/Contents/PlugIns/EPUBThumbnailExtension.appex"
mkdir -p "$THUMB/Contents/MacOS"
compile "$THUMB/Contents/MacOS/EPUBThumbnailExtension" \
	"-Xlinker -e -Xlinker _NSExtensionMain -parse-as-library" \
	"${KIT_SOURCES[@]}" "$ROOT"/Sources/ThumbnailExtension/*.swift \
	-framework Cocoa -framework QuickLookThumbnailing

echo "==> 번들 구성"
cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Preview-Info.plist" "$PREVIEW/Contents/Info.plist"
cp "$ROOT/Resources/Thumbnail-Info.plist" "$THUMB/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
rm -rf "$BUILD/obj"

echo "==> 코드 서명 (ad-hoc)"
codesign --force --sign - --timestamp=none \
	--entitlements "$ROOT/Resources/Extension.entitlements" "$PREVIEW"
codesign --force --sign - --timestamp=none \
	--entitlements "$ROOT/Resources/Extension.entitlements" "$THUMB"
codesign --force --sign - --timestamp=none \
	--entitlements "$ROOT/Resources/App.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

echo "빌드 완료: $APP"

if [[ "${1:-}" == "install" ]]; then
	echo "==> $INSTALL_DIR 에 설치"
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

	echo "설치 완료. Finder에서 .epub 파일을 선택하고 스페이스바를 눌러보세요."
	echo "등록 상태 확인: pluginkit -m -p com.apple.quicklook.preview | grep -i epub"
fi
