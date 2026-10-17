#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift scripts/generate-icon.swift
iconutil -c icns build/Nanflow.iconset -o scripts/AppIcon.icns
echo "Updated scripts/AppIcon.icns"
