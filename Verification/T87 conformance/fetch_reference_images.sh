#!/usr/bin/env bash
# Copyright (C) 2026 Vitor Mendes Camilo
# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of OpenJLS. Available under GPLv3 or a
# commercial license. See LICENSE and README for details.
#

# Download the ITU T.87 test images into Reference Images/
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REF_DIR="$SCRIPT_DIR/Reference Images"
ZIP_URL="https://www.itu.int/rec/dologin_pub.asp?lang=e&id=T-REC-T.87-199806-I!!ZPF-E&type=items"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

echo "Downloading T.87 reference package..."
curl -L -o "$WORK_DIR/t87.zip" "$ZIP_URL"

echo "Extracting outer archive..."
unzip -q "$WORK_DIR/t87.zip" -d "$WORK_DIR/t87"

echo "Extracting Software.zip..."
unzip -q "$WORK_DIR/t87/software/T87/Software.zip" -d "$WORK_DIR/software"

echo "Extracting jlsimgV100.zip..."
unzip -q "$WORK_DIR/software/software/T87/jlsimgV100.zip" -d "$WORK_DIR/jlsimgV100"

echo "Copying reference images to $REF_DIR..."
mkdir -p "$REF_DIR"
cp "$WORK_DIR"/jlsimgV100/* "$REF_DIR/"

echo "Done. Reference images are in: $REF_DIR/"
ls "$REF_DIR/"
