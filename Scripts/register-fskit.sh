#!/bin/bash
#
# Registers macFUSE's FSKit file-system extensions with PluginKit so they show
# up in Ajustes del Sistema → General → Elementos de inicio y extensiones →
# Extensiones del sistema de archivos.
#
# Why this exists: macFUSE ships the extensions inside its installed filesystem
# bundle, but they are frequently *not* registered after an install or upgrade,
# and neither `macfuse install --components file-system-extensions --force` nor
# `lsregister -f` fixes it — both exit 0 and register nothing (reproduced on
# macFUSE 5.3.3 / macOS 26.6.2). Without registration the toggle the user is
# told to flip simply is not in the list, and `-o backend=fskit` fails with
# "File system extension not enabled". `pluginkit -a` is the workaround from
# macfuse/macfuse#1071.
#
# What this does NOT do: enable the extension. Registration only makes it
# appear; the switch itself is the user's, and there is no API or command that
# can flip it. That is why this script ends by pointing at the pane.
#
# No sudo needed — PluginKit registration is per-user.
set -euo pipefail

EXTENSIONS_DIR="/Library/Filesystems/macfuse.fs/Contents/Resources/macfuse.app/Contents/Extensions"

if [ ! -d "$EXTENSIONS_DIR" ]; then
    echo "error: macFUSE no está instalado, o es una versión anterior a la que trae el módulo FSKit."
    echo "       Se esperaba encontrar: $EXTENSIONS_DIR"
    exit 1
fi

registered=0
for appex in "$EXTENSIONS_DIR"/*.appex; do
    [ -d "$appex" ] || continue
    # -a adds; re-adding an already-registered extension is a no-op, so this is
    # safe to run repeatedly.
    if pluginkit -v -a "$appex"; then
        registered=$((registered + 1))
    else
        echo "warning: no se pudo registrar $(basename "$appex")"
    fi
done

if [ "$registered" -eq 0 ]; then
    echo "error: no se registró ninguna extensión."
    exit 1
fi

echo
echo "Registradas $registered extensión(es). Estado actual:"
pluginkit -m -p com.apple.fskit.fsmodule -v || true

echo
echo "Falta el último paso, que solo podés hacer vos:"
echo "  Ajustes del Sistema → General → Elementos de inicio y extensiones"
echo "  → Extensiones del sistema de archivos → activar macFUSE"
echo
echo "Después, volvé a AppNTFS y usá \"Recomprobar dependencias\"."
