#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
用法：package-app.sh [--zip]

构建 Release SwiftPM 可执行文件，组装并 ad-hoc 签名：
  dist/Woo Todo.app

选项：
  --zip    同时生成便于传输的 zip 包
  --help   显示本帮助

可选环境变量：
  BUNDLE_ID          Bundle Identifier，默认 io.github.stophemo.woo-todo
  MARKETING_VERSION  显示版本，默认 0.1.1
  BUILD_NUMBER       构建号，仅允许数字，默认 2
EOF
}

fail() {
    printf '错误：%s\n' "$1" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "缺少系统命令：$1"
}

CREATE_ZIP=0
while (( $# > 0 )); do
    case "$1" in
        --zip)
            CREATE_ZIP=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "未知参数：$1"
            ;;
    esac
    shift
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
MACOS_DIR="$(cd -- "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd -P)"
TEMPLATE_PLIST="$MACOS_DIR/Resources/Info.plist"
ICON_RESOURCE="$MACOS_DIR/Resources/AppIcon.icns"
ICON_FILE_NAME="AppIcon.icns"
DIST_DIR="$MACOS_DIR/dist"
APP_NAME="Woo Todo"
EXECUTABLE_NAME="woo-todo-mac"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

BUNDLE_ID="${BUNDLE_ID:-io.github.stophemo.woo-todo}"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.1}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"

[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
    || fail "BUNDLE_ID 只能包含字母、数字、点和连字符"
[[ "$BUNDLE_ID" != *..* ]] || fail "BUNDLE_ID 不能包含连续的点"
[[ "$MARKETING_VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
    || fail "MARKETING_VERSION 格式无效"
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "BUILD_NUMBER 必须是数字"

require_command swift
require_command /usr/bin/codesign
require_command /usr/bin/ditto
require_command /usr/bin/iconutil
require_command /usr/bin/plutil
require_command /usr/libexec/PlistBuddy
[[ -f "$TEMPLATE_PLIST" ]] || fail "找不到 Info.plist 模板：$TEMPLATE_PLIST"
[[ -s "$ICON_RESOURCE" ]] || fail "找不到 App 图标：$ICON_RESOURCE"

umask 022
mkdir -p -- "$DIST_DIR"
STAGING_DIR="$(mktemp -d "$DIST_DIR/.package-app.XXXXXX")"

cleanup() {
    if [[ -n "${STAGING_DIR:-}" && -d "$STAGING_DIR" ]]; then
        rm -rf -- "$STAGING_DIR"
    fi
}
trap cleanup EXIT

printf '正在构建 Release 可执行文件…\n'
cd -- "$MACOS_DIR"
swift build -c release --product "$EXECUTABLE_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"
BUILT_EXECUTABLE="$BIN_DIR/$EXECUTABLE_NAME"
[[ -x "$BUILT_EXECUTABLE" ]] || fail "没有找到 Release 产物：$BUILT_EXECUTABLE"

STAGED_APP="$STAGING_DIR/$APP_NAME.app"
CONTENTS_DIR="$STAGED_APP/Contents"
mkdir -p -- "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"
/usr/bin/install -m 0755 "$BUILT_EXECUTABLE" "$CONTENTS_DIR/MacOS/$EXECUTABLE_NAME"
/usr/bin/install -m 0644 "$TEMPLATE_PLIST" "$CONTENTS_DIR/Info.plist"
/usr/bin/install -m 0644 "$ICON_RESOURCE" "$CONTENTS_DIR/Resources/$ICON_FILE_NAME"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS_DIR/Info.plist"
/usr/bin/plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

PLIST_ICON_FILE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$CONTENTS_DIR/Info.plist")"
[[ "$PLIST_ICON_FILE" == "$ICON_FILE_NAME" ]] \
    || fail "Info.plist 的 CFBundleIconFile 必须指向 $ICON_FILE_NAME"

ICONSET_CHECK_DIR="$STAGING_DIR/AppIcon.iconset"
if ! /usr/bin/iconutil \
    -c iconset \
    "$CONTENTS_DIR/Resources/$ICON_FILE_NAME" \
    -o "$ICONSET_CHECK_DIR"; then
    fail "$ICON_FILE_NAME 不是有效的 macOS 图标资源"
fi

EXPECTED_ICON_FILES=(
    icon_16x16.png
    icon_16x16@2x.png
    icon_32x32.png
    icon_32x32@2x.png
    icon_128x128.png
    icon_128x128@2x.png
    icon_256x256.png
    icon_256x256@2x.png
    icon_512x512.png
    icon_512x512@2x.png
)
for icon_file in "${EXPECTED_ICON_FILES[@]}"; do
    [[ -s "$ICONSET_CHECK_DIR/$icon_file" ]] \
        || fail "$ICON_FILE_NAME 缺少标准尺寸：$icon_file"
done

printf '正在执行 ad-hoc 签名…\n'
/usr/bin/codesign \
    --force \
    --sign - \
    --timestamp=none \
    "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# 输出路径固定在当前 Package 的 dist 下，避免环境变量造成越界删除。
rm -rf -- "$APP_BUNDLE"
mv -- "$STAGED_APP" "$APP_BUNDLE"

printf 'App 已生成：%s\n' "$APP_BUNDLE"

if (( CREATE_ZIP == 1 )); then
    ZIP_PATH="$DIST_DIR/$APP_NAME-$MARKETING_VERSION-macos.zip"
    rm -f -- "$ZIP_PATH"
    printf '正在生成 zip…\n'
    /usr/bin/ditto \
        -c \
        -k \
        --sequesterRsrc \
        --keepParent \
        "$APP_BUNDLE" \
        "$ZIP_PATH"
    printf 'zip 已生成：%s\n' "$ZIP_PATH"
fi

printf '完成。首次启动若被系统拦截，请在“系统设置 → 隐私与安全性”中手动允许。\n'
