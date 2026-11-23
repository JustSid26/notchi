#!/bin/bash
# Render the cat to build/cat-poses.png and build/cat-demo.gif (no app launch needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -o build/preview-cat \
  Sources/Notchi/Cat/CatEngine.swift \
  Sources/Notchi/Cat/CatRenderer.swift \
  Sources/Notchi/Cat/DogParts.swift \
  Sources/Notchi/Cat/BirdRenderer.swift \
  Sources/Notchi/Settings/AppSettings.swift \
  scripts/preview-cat/main.swift
./build/preview-cat build
