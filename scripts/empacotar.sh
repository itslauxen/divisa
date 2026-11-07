#!/usr/bin/env bash
# Gera os pacotes da versão em dist/: Divisa-mac.zip (universal) e Divisa-windows.exe (com o .NET dentro).
# Uso: scripts/empacotar.sh   (no Mac, com o .NET 8 SDK para gerar o .exe)
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf dist && mkdir -p dist

# Mac: Apple Silicon e Intel no mesmo app, com assinatura anônima (ad hoc).
(
  cd mac
  swift build -c release --arch arm64 --arch x86_64
  BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
  APP=../dist/Divisa.app
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$BIN/Divisa" "$APP/Contents/MacOS/Divisa"
  cp Info.plist "$APP/Contents/Info.plist"
  cp -R web "$APP/Contents/Resources/web"
  codesign --force --sign - "$APP"
)
(cd dist && ditto -c -k --keepParent Divisa.app Divisa-mac.zip && rm -rf Divisa.app)

# Windows: um .exe só, que roda sem instalar o .NET.
DOTNET=$(command -v dotnet || echo "$HOME/.dotnet/dotnet")
"$DOTNET" publish windows/Divisa/Divisa.csproj -c Release -r win-x64 --self-contained \
  -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -o dist/windows
mv dist/windows/Divisa.exe dist/Divisa-windows.exe
rm -rf dist/windows

ls -lh dist
