#!/usr/bin/env bash
set -e

RUNTIME="${1:-linux-x64}"

if [[ "$RUNTIME" != "linux-x64" && "$RUNTIME" != "linux-arm64" ]]; then
  echo "Usage: ./publish-linux.sh [linux-x64|linux-arm64]"
  exit 1
fi

dotnet restore
dotnet publish ./ChtrFmtr.Avalonia.csproj \
  -c Release \
  -r "$RUNTIME" \
  --self-contained true

echo
echo "Published to:"
echo "bin/Release/net10.0/$RUNTIME/publish/"
