#!/usr/bin/env bash
# Compila e empacota o Divisa.app.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="Divisa.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Divisa "$APP/Contents/MacOS/Divisa"
cp Info.plist "$APP/Contents/Info.plist"
[ -d web ] && cp -R web "$APP/Contents/Resources/web"
# Com um certificado "Apple Development" a identidade fica fixa e o macOS não pede as permissões de novo a cada build.
IDENTIDADE=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')
codesign --force --sign "${IDENTIDADE:--}" "$APP"
echo "Assinado com: ${IDENTIDADE:-ad hoc}"
echo "Pronto: $(pwd)/$APP"
