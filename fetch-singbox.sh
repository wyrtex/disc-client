#!/bin/bash
# Собирает Libbox.xcframework из официальных исходников sing-box (SagerNet), версия закреплена.
# Нужен только локальный прокси (mixed inbound на 127.0.0.1) — без TUN/системного VPN,
# поэтому в теги сборки не включаем with_wireguard/with_gvisor и т.п.
set -euo pipefail

SINGBOX_TAG="v1.14.1"
GOMOBILE_VERSION="v0.1.12"
GO_VERSION="1.23.4"

if [ -d "Vendor/Libbox.xcframework" ]; then
  echo "Libbox.xcframework уже есть, пропускаю сборку"
  exit 0
fi

echo "### Сборка Libbox.xcframework (sing-box ${SINGBOX_TAG})" >> "$GITHUB_STEP_SUMMARY"

if ! command -v go >/dev/null 2>&1; then
  curl -L --fail -o go.pkg "https://go.dev/dl/go${GO_VERSION}.darwin-arm64.pkg"
  sudo installer -pkg go.pkg -target /
  rm go.pkg
fi
export PATH="/usr/local/go/bin:$PATH:$(go env GOPATH)/bin"
go version

go install -v "github.com/sagernet/gomobile/cmd/gomobile@${GOMOBILE_VERSION}"
go install -v "github.com/sagernet/gomobile/cmd/gobind@${GOMOBILE_VERSION}"
gomobile init

WORKDIR=$(mktemp -d)
git clone --branch "$SINGBOX_TAG" --depth 1 https://github.com/SagerNet/sing-box.git "$WORKDIR/sing-box"
cd "$WORKDIR/sing-box"

# Только то, что нужно клиенту VLESS+REALITY: uTLS для отпечатка (fp=firefox).
# with_reality_server/with_wireguard/with_gvisor и т.п. не нужны — мы не сервер и не TUN.
TAGS="with_utls"
gomobile bind -v -target ios,iossimulator -tags "$TAGS" -trimpath -ldflags "-s -w" \
  -o "$OLDPWD/Vendor/Libbox.xcframework" \
  ./experimental/libbox

cd "$OLDPWD"
rm -rf "$WORKDIR"

ls Vendor/Libbox.xcframework
echo "Libbox.xcframework собран (теги: ${TAGS})" >> "$GITHUB_STEP_SUMMARY"
