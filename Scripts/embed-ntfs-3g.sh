#!/bin/bash
#
# Copies ntfs-3g, ntfs-3g.probe and ntfsfix — plus the Homebrew dylibs they
# link against — into the app bundle, and rewrites their load commands so they
# resolve inside it.
#
# Why: without this the user has to install Homebrew, add a third-party tap and
# `brew install ntfs-3g-mac` before the app can mount anything. The binaries are
# ~1 MB; shipping them removes that entire manual step. `DependencyChecker`
# prefers these copies and falls back to Homebrew if the embed didn't run.
#
# What this does NOT remove: macFUSE. `ntfs-3g` links `/usr/local/lib/libfuse.2
# .dylib` at an absolute path, and that library is the userspace half of a kext
# the user must install and approve anyway — there is nothing to embed.
#
# Run as an Xcode build phase (see project.yml). Outside Xcode, set
# BUILT_PRODUCTS_DIR / CONTENTS_FOLDER_PATH by hand.
set -euo pipefail

: "${BUILT_PRODUCTS_DIR:?must run as an Xcode build phase}"
: "${CONTENTS_FOLDER_PATH:?must run as an Xcode build phase}"

BINARIES=(ntfs-3g ntfs-3g.probe ntfsfix)

# Libraries that stay absolute. Everything else reachable from the binaries is
# copied in and rewritten.
#   /usr/lib, /System — the OS dylib cache; not ours to ship, and shipping a
#                       copy would pin the app to one macOS version.
#   libfuse           — macFUSE's, installed by the user at a fixed path.
is_system_library() {
    case "$1" in
        /usr/lib/*|/System/*|/usr/local/lib/libfuse.*|/opt/homebrew/lib/libfuse.*) return 0 ;;
        *) return 1 ;;
    esac
}

resolve_source_directory() {
    if [ -n "${NTFS3G_BIN_DIR:-}" ]; then
        echo "$NTFS3G_BIN_DIR"
        return
    fi
    # `opt/<formula>` is Homebrew's stable per-formula symlink; it exists
    # whether or not the formula is linked into `bin`.
    for prefix in /opt/homebrew /usr/local; do
        if [ -x "$prefix/opt/ntfs-3g-mac/bin/ntfs-3g" ]; then
            echo "$prefix/opt/ntfs-3g-mac/bin"
            return
        fi
    done
}

SOURCE_DIR="$(resolve_source_directory)"
if [ -z "$SOURCE_DIR" ]; then
    INSTALL_HINT="Install it with: brew tap gromgit/homebrew-fuse && brew install ntfs-3g-mac"
    # For a local build this is a warning, not an error: the app still builds
    # and runs, it just falls back to requiring Homebrew on the user's machine.
    # Failing here would block anyone who only wants to compile the app.
    #
    # For a *release* build it has to be fatal, which is what
    # REQUIRE_EMBEDDED_NTFS3G is for (set by .github/workflows/release.yml).
    # Shipping the fallback silently would produce a release that still demands
    # a third-party tap from every user — the exact thing embedding removes —
    # and nothing downstream would notice, since the app degrades gracefully.
    if [ "${REQUIRE_EMBEDDED_NTFS3G:-0}" = "1" ]; then
        echo "error: ntfs-3g-mac not found, and REQUIRE_EMBEDDED_NTFS3G is set. $INSTALL_HINT"
        exit 1
    fi
    echo "warning: ntfs-3g-mac not found — the app will be built without embedded binaries and will require Homebrew at runtime. $INSTALL_HINT"
    exit 0
fi

# The keg root holds COPYING/COPYING.LIB and AUTHORS next to bin/. Resolved
# through symlinks so the version can be read off it: `opt/ntfs-3g-mac` is the
# stable alias, `Cellar/ntfs-3g-mac/<version>` is what it points at.
SOURCE_ROOT="$(cd "$(dirname "$SOURCE_DIR")" && pwd -P)"
SOURCE_VERSION="$(basename "$SOURCE_ROOT")"

CONTENTS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"
HELPERS_DIR="$CONTENTS/Helpers"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
mkdir -p "$HELPERS_DIR" "$FRAMEWORKS_DIR"

# Transitive closure over the non-system dependencies. ntfs-3g today pulls in
# libntfs-3g and libintl, and libintl pulls in nothing further — but the set is
# walked rather than hardcoded so a formula update can't silently ship a bundle
# with a dangling load command.
#
# Plain indexed arrays with a cursor, no associative arrays and no shifting:
# macOS ships bash 3.2, where `declare -A` does not exist and expanding an
# emptied array under `set -u` is an error.
QUEUE=""      # newline-separated paths still to process
COPIED=""     # newline-separated paths already copied into Frameworks

contains_line() {
    printf '%s\n' "$2" | grep -qxF "$1"
}

queue_dependencies() {
    local target="$1" dependency
    # `otool -L` prints the file name on line 1 and one dependency per line
    # after; each dependency line is "\t<path> (compatibility ...)".
    otool -L "$target" | tail -n +2 | awk '{print $1}' | while read -r dependency; do
        [ -n "$dependency" ] || continue
        printf '%s\n' "$dependency"
    done
}

# Collect every dependency edge first, then process the worklist. Done in two
# passes because the pipeline above runs in a subshell, so it cannot append to
# a variable in this one.
enqueue() {
    local dependency
    for dependency in $(queue_dependencies "$1"); do
        is_system_library "$dependency" && continue
        contains_line "$dependency" "$QUEUE" && continue
        QUEUE="$QUEUE$dependency
"
    done
}

for binary in "${BINARIES[@]}"; do
    source_path="$SOURCE_DIR/$binary"
    if [ ! -x "$source_path" ]; then
        echo "error: $source_path is missing from the ntfs-3g-mac install"
        exit 1
    fi
    install -m 755 "$source_path" "$HELPERS_DIR/$binary"
    enqueue "$HELPERS_DIR/$binary"
done

# The worklist grows while it is walked (a copied library can pull in more), so
# it is re-read from the top on every pass until a pass adds nothing.
while :; do
    pending=""
    for dependency in $(printf '%s' "$QUEUE"); do
        contains_line "$dependency" "$COPIED" && continue
        pending="$dependency"
        break
    done
    [ -n "$pending" ] || break

    if [ ! -f "$pending" ]; then
        echo "error: $pending is required by ntfs-3g but does not exist"
        exit 1
    fi
    # Homebrew reaches the same library by more than one path: dependents
    # record the stable `opt/<formula>/lib/...` symlink, while the library's
    # own LC_ID_DYLIB points into `Cellar/<formula>/<version>/lib/...`. Both
    # strings must end up in COPIED so both get rewritten, but the file itself
    # is copied once — the basename is the identity here, since that is also
    # what the flat Frameworks layout keys on.
    name="$(basename "$pending")"
    COPIED="$COPIED$pending
"
    if [ -f "$FRAMEWORKS_DIR/$name" ]; then
        continue
    fi
    install -m 755 "$pending" "$FRAMEWORKS_DIR/$name"
    enqueue "$FRAMEWORKS_DIR/$name"
done

# Rewrite the load commands. Executables sit in Contents/Helpers and the
# libraries in Contents/Frameworks, so @executable_path/../Frameworks is right
# for both — and for the libraries it stays right regardless of which of the
# three executables loaded them, which @loader_path would not.
rewrite() {
    local target="$1" original name
    for original in $(printf '%s' "$COPIED"); do
        name="$(basename "$original")"
        install_name_tool -change "$original" "@executable_path/../Frameworks/$name" "$target" 2>/dev/null || true
    done
}

for library in "$FRAMEWORKS_DIR"/*; do
    [ -f "$library" ] || continue
    # The install name is what *dependents* record, so it has to be fixed
    # before anything is signed, not just the outgoing -change entries.
    install_name_tool -id "@executable_path/../Frameworks/$(basename "$library")" "$library"
    rewrite "$library"
done

for binary in "${BINARIES[@]}"; do
    rewrite "$HELPERS_DIR/$binary"
done

# install_name_tool invalidates the existing signature, and a stale-signed
# Mach-O inside a signed bundle is killed on launch. Re-sign everything that
# was touched — libraries before the executables that load them.
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -z "$IDENTITY" ] && IDENTITY="-"

# The hardened runtime enables library validation, which requires the loaded
# library and the loading process to share a Team ID. Ad-hoc signatures carry
# no Team ID, so enabling it on a local unsigned build makes every embedded
# binary fail to launch:
#
#     Reason: … not valid for use in process: mapping process and mapped
#     file (non-platform) have different Team IDs
#
# With a real identity both sides are signed by the same team and it passes —
# and it is required for notarization, so it stays on wherever it can work.
HARDENED_RUNTIME_FLAGS="--options runtime"
if [ "$IDENTITY" = "-" ]; then
    HARDENED_RUNTIME_FLAGS=""
fi

for target in "$FRAMEWORKS_DIR"/* "$HELPERS_DIR"/*; do
    [ -f "$target" ] || continue
    codesign --force --sign "$IDENTITY" --timestamp=none $HARDENED_RUNTIME_FLAGS "$target"
done

# GPLv2 obligation, not a nicety: ntfs-3g is GPLv2 and libntfs-3g LGPLv2, so
# distributing these binaries requires shipping their licence texts and telling
# the recipient where the corresponding source is. AppNTFS itself is a separate
# work that only executes them, which is why it can keep its own licence.
LICENSE_DIR="$CONTENTS/Resources/ntfs-3g"
mkdir -p "$LICENSE_DIR"
for licence in COPYING COPYING.LIB AUTHORS; do
    if [ -f "$SOURCE_ROOT/$licence" ]; then
        install -m 644 "$SOURCE_ROOT/$licence" "$LICENSE_DIR/$licence"
    fi
done

cat > "$LICENSE_DIR/README.txt" <<NOTICE
AppNTFS incluye copias de ntfs-3g, ntfs-3g.probe y ntfsfix (en Contents/Helpers)
y de las librerías que necesitan (en Contents/Frameworks).

Esos programas NO forman parte de AppNTFS: son obra del proyecto ntfs-3g y se
distribuyen bajo la GNU General Public License v2 (ver COPYING); la librería
libntfs-3g se distribuye bajo la GNU Lesser General Public License v2 (ver
COPYING.LIB). Los autores están listados en AUTHORS.

El código fuente correspondiente está disponible en:

    https://github.com/tuxera/ntfs-3g

La versión empotrada en esta copia de AppNTFS es la $SOURCE_VERSION, tal como la
empaqueta la fórmula ntfs-3g-mac del tap gromgit/homebrew-fuse:

    https://github.com/gromgit/homebrew-fuse

Los únicos cambios aplicados a los binarios son de reubicación: sus rutas de
carga (LC_LOAD_DYLIB / LC_ID_DYLIB) se reescriben con install_name_tool para
que apunten dentro del bundle, y se vuelven a firmar. El código ejecutable no
se modifica. El script que hace eso es Scripts/embed-ntfs-3g.sh en el
repositorio de AppNTFS.
NOTICE

echo "Embedded ntfs-3g from $SOURCE_DIR ($(ls -1 "$FRAMEWORKS_DIR" | wc -l | tr -d ' ') bundled libraries)"
