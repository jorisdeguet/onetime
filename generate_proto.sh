#!/bin/bash
# ============================================================
# Script pour générer le code Dart à partir des fichiers .proto
# ============================================================
#
# PRÉREQUIS:
# 1. Installer protoc:
#    - macOS: brew install protobuf
#    - Ubuntu/Debian: apt install protobuf-compiler
#    - Fedora: dnf install protobuf-compiler
#
# 2. Activer le plugin Dart:
#    dart pub global activate protoc_plugin
#
# ============================================================

set -e

echo ""
echo "=== Protobuf Code Generator ==="
echo ""

# Vérifier si protoc est installé
if ! command -v protoc &> /dev/null; then
    echo "ERROR: protoc n'est pas installé!"
    echo ""
    echo "Pour installer protoc:"
    echo "  macOS:        brew install protobuf"
    echo "  Ubuntu/Debian: sudo apt install protobuf-compiler"
    echo "  Fedora:       sudo dnf install protobuf-compiler"
    echo ""
    echo "OU utiliser notre implémentation manuelle dans lib/services/metadata_proto.dart"
    echo "qui est déjà fonctionnelle et compatible avec le format wire protobuf."
    echo ""
    exit 1
fi

echo "protoc trouvé: $(protoc --version)"
echo ""

# S'assurer que le plugin Dart est activé (version 21.1.2 compatible avec protobuf 3.1.0)
echo "Activation du plugin protoc-gen-dart v21.1.2..."
dart pub global activate protoc_plugin 21.1.2
echo ""

# Ajouter le chemin du plugin au PATH
export PATH="$PATH:$HOME/.pub-cache/bin"

# Créer le dossier de sortie
mkdir -p lib/services/generated

# Générer le code Dart
echo "Génération du code Dart..."
protoc --dart_out=lib/services/generated \
       --proto_path=lib/convo \
       lib/convo/message_metadata.proto

echo ""
echo "=== Succès! ==="
echo "Code généré dans: lib/services/generated/"
echo ""

