#!/bin/bash
# Скачивает готовую библиотеку sherpa-onnx для iOS (движок озвучки Pocket TTS).
set -e
VER="1.13.8"
URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v${VER}-ios-shared-onnxruntime-static.xcframework.zip"

mkdir -p Vendor
if [ ! -d Vendor/SherpaOnnxC.xcframework ]; then
  curl -L --fail --retry 5 --retry-delay 3 -o Vendor/sherpa.zip "$URL"
  unzip -q Vendor/sherpa.zip -d Vendor
  rm -f Vendor/sherpa.zip
fi

ls Vendor/SherpaOnnxC.xcframework
echo "### sherpa-onnx ${VER}: библиотека подключена" >> "$GITHUB_STEP_SUMMARY"
