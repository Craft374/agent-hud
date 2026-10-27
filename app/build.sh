#!/usr/bin/env bash
# app/build/Agent HUD.app 을 만든다 (Xcode 없이 Command Line Tools만 있으면 된다).
#   app/build.sh            빌드
#   app/build.sh --install  빌드 후 /Applications 에 복사
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# Command Line Tools의 컴파일러가 모듈 충돌로 안 도는 경우가 있어 Xcode가 있으면 그쪽을 쓴다.
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
APP="build/Agent HUD.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos12.0" AgentHUD.swift -o "$APP/Contents/MacOS/AgentHUD"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/"
cp ../server.py "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "built: $PWD/$APP"
if [ "${1:-}" = "--install" ]; then
  rm -rf "/Applications/Agent HUD.app" && cp -R "$APP" /Applications/
  echo "installed: /Applications/Agent HUD.app"
fi
