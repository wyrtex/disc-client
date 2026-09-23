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
  export PATH="/usr/local/go/bin:$PATH"
  rm go.pkg
fi
go version

# Не полагаемся на PATH для только что установленных бинарников — на некоторых раннерах
# каталог с ними в PATH не попадает. Вычисляем путь заново и обращаемся к бинарнику напрямую.
GOBIN_DIR="$(go env GOBIN)"
if [ -z "$GOBIN_DIR" ]; then
  GOBIN_DIR="$(go env GOPATH)/bin"
fi
echo "GOBIN_DIR=${GOBIN_DIR}"

go install -v "github.com/sagernet/gomobile/cmd/gomobile@${GOMOBILE_VERSION}"
go install -v "github.com/sagernet/gomobile/cmd/gobind@${GOMOBILE_VERSION}"

GOMOBILE_BIN="${GOBIN_DIR}/gomobile"
if [ ! -x "$GOMOBILE_BIN" ]; then
  echo "Не нашёл gomobile по ожидаемому пути: ${GOMOBILE_BIN}"
  echo "Содержимое ${GOBIN_DIR}:"
  ls -la "$GOBIN_DIR" || true
  exit 1
fi
export PATH="${GOBIN_DIR}:$PATH"

"$GOMOBILE_BIN" init

WORKDIR=$(mktemp -d)
git clone --branch "$SINGBOX_TAG" --depth 1 https://github.com/SagerNet/sing-box.git "$WORKDIR/sing-box"
cd "$WORKDIR/sing-box"

# Только то, что нужно клиенту VLESS+REALITY: uTLS для отпечатка (fp=firefox).
# with_reality_server/with_wireguard/with_gvisor и т.п. не нужны — мы не сервер и не TUN.
TAGS="with_utls"
"$GOMOBILE_BIN" bind -v -target ios,iossimulator -tags "$TAGS" -trimpath -ldflags "-s -w" \
  -o "$OLDPWD/Vendor/Libbox.xcframework" \
  ./experimental/libbox

cd "$OLDPWD"
rm -rf "$WORKDIR"

ls Vendor/Libbox.xcframework
echo "Libbox.xcframework собран (теги: ${TAGS})" >> "$GITHUB_STEP_SUMMARY"

# Диагностика: печатаем настоящие объявления из сгенерированного заголовка, чтобы не гадать
# вслепую про имена и сигнатуры методов — берём только то, что реально нужно для интеграции.
HEADER=$(find Vendor/Libbox.xcframework -name "Libbox.h" -path "*ios-arm64/*" | head -1)
if [ -z "$HEADER" ]; then
  HEADER=$(find Vendor/Libbox.xcframework -name "Libbox.h" | head -1)
fi
if [ -n "$HEADER" ]; then
  {
    echo "### Настоящие объявления из Libbox.h (для интеграции)"
    echo '```objc'
    grep -n -A2 -B2       -e "PlatformInterface"       -e "@interface LibboxBoxService"       -e "LibboxNewService"       -e "NewStandaloneCommandClient"       -e "@protocol LibboxLocalDNSTransportProtocol"       -e "@protocol LibboxNetworkInterfaceIteratorProtocol"       -e "@protocol LibboxInterfaceUpdateListenerProtocol"       -e "@protocol LibboxStringIteratorProtocol"       -e "@protocol LibboxTunOptionsProtocol"       -e "LibboxNotification"       -e "LibboxWIFIState"       "$HEADER" | head -400
    echo '```'
  } >> "$GITHUB_STEP_SUMMARY"
else
  echo "Не нашёл Libbox.h внутри framework — структура папок другая, чем ожидалось." >> "$GITHUB_STEP_SUMMARY"
  find Vendor/Libbox.xcframework -maxdepth 4 >> "$GITHUB_STEP_SUMMARY"
fi
