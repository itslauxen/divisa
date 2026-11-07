#!/usr/bin/env bash
# Instala (ou atualiza) a Divisa no Mac:
#   curl -fsSL https://raw.githubusercontent.com/itslauxen/divisa/main/instalar.sh | bash
set -euo pipefail

# DIVISA_URL e DIVISA_DESTINO trocam a origem e a pasta (para testar o instalador sem mexer no app instalado).
URL="${DIVISA_URL:-https://github.com/itslauxen/divisa/releases/latest/download/Divisa-mac.zip}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "Baixando a Divisa…"
curl -fsSL "$URL" -o "$TMP/Divisa.zip"

# Fecha a versão aberta, se houver, antes de trocar.
DESTINO="${DIVISA_DESTINO:-/Applications}"
if [ -z "${DIVISA_DESTINO:-}" ]; then
  osascript -e 'quit app "Divisa"' >/dev/null 2>&1 || true
  sleep 1
  [ -w "$DESTINO" ] || { DESTINO="$HOME/Applications"; mkdir -p "$DESTINO"; }
fi
rm -rf "$DESTINO/Divisa.app"
ditto -x -k "$TMP/Divisa.zip" "$DESTINO"
# O app não é notarizado pela Apple; sem a marca de quarentena o macOS abre direto.
xattr -dr com.apple.quarantine "$DESTINO/Divisa.app" 2>/dev/null || true

[ -n "${DIVISA_DESTINO:-}" ] || open "$DESTINO/Divisa.app"
cat <<'FIM'

Pronto! A Divisa está na barra de menus (ícone de dois retângulos).
Na primeira vez, libere em Ajustes do Sistema › Privacidade e Segurança:
  • Acessibilidade      (para dividir o mouse e o teclado)
  • Gravação de Tela    (só para usar o tablet como segunda tela)
Depois instale no Windows:  irm https://raw.githubusercontent.com/itslauxen/divisa/main/instalar.ps1 | iex
FIM
