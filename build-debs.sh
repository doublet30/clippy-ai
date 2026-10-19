#!/usr/bin/env bash
# Build the project and three Debian packages into ./dist:
#   clippy-ai                    program   -> /opt/ttos/clippy-ai, /usr/local/bin/clippy-ai, .desktop entries, icon
#   clippy-ai-themes-free        DFSG-free mascot themes (Tux, Konqi, Wilber, Larry)   -> /opt/ttos/clippy-ai/themes
#   clippy-ai-themes-non-free    Microsoft Agent characters (Clippit, Merlin, ...)     -> /opt/ttos/clippy-ai/themes
#
# Usage: ./build-debs.sh      (env overrides: VERSION, MAINTAINER, PROJECT_LICENSE, JOBS)
# Everything is staged under ./build and written to ./dist - nothing is installed on this machine.
set -euo pipefail
ROOT=$(dirname "$(readlink -f "$0")")
cd "$ROOT"

NAME=revvy-ai
PREFIX=/opt/ttos/$NAME
VERSION=${VERSION:-$(cat VERSION)}
ARCH=$(dpkg --print-architecture)
JOBS=${JOBS:-$(nproc)}
PROJECT_LICENSE=${PROJECT_LICENSE:-GPL-3+}      # DEP-5 short name for the program's own code
GIT_NAME=$(git config user.name 2>/dev/null || true)
GIT_MAIL=$(git config user.email 2>/dev/null || true)
MAINTAINER=${MAINTAINER:-"${GIT_NAME:-Unknown} <${GIT_MAIL:-unknown@example.com}>"}
YEAR=$(date +%Y)
DATE_RFC=$(date -R)
HOMEPAGE=${HOMEPAGE:-https://github.com/doublet30/revvy-ai}

FREE_THEMES=(tux konqi konqi-classic wilber larry)
NONFREE_THEMES=(bonzi clippy f1 genie genius links merlin peedy rocky rover)
# Renderer plug-ins belong to the program package rather than an artwork
# package.  They still use an agent.json manifest so the existing Config and
# CLI selection paths can discover them alongside sprite themes.
CORE_THEMES=(circle-ai)
VOSK_MODEL_NAME=vosk-model-small-en-us-0.15
VOSK_MODEL_ARCHIVE=${VOSK_MODEL_ARCHIVE:-$HOME/.local/share/ttos/assistant/${VOSK_MODEL_NAME}.tar.gz}
VOSK_MODEL_URL=https://alphacephei.com/vosk/models/${VOSK_MODEL_NAME}.zip

BUILD=$ROOT/build
DIST=$ROOT/dist
STAGE=$BUILD/stage
log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- every theme must be classified
log "Checking theme classification"
for d in themes/*/; do
    t=$(basename "$d")
    [[ " ${FREE_THEMES[*]} ${NONFREE_THEMES[*]} ${CORE_THEMES[*]} " == *" $t "* ]] || { echo "ERROR: theme '$t' is in neither FREE_THEMES, NONFREE_THEMES nor CORE_THEMES"; exit 1; }
done
for t in "${FREE_THEMES[@]}"; do
    [[ -f themes/$t/agent.json ]] || { echo "ERROR: themes/$t/agent.json missing"; exit 1; }
done
# The Microsoft Agent themes are not kept in the public git repo; skip that package when they are absent.
HAVE_NONFREE=1
for t in "${NONFREE_THEMES[@]}"; do [[ -f themes/$t/agent.json ]] || HAVE_NONFREE=0; done
(( HAVE_NONFREE )) || echo "NOTE: non-free themes not present in themes/ - skipping clippy-ai-themes-non-free"

# ---------------------------------------------------------------- build the C++ config tool
log "Building revvy-ai-config"
cmake -S config-tool -B "$BUILD/config-tool" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD/config-tool" -j"$JOBS"

rm -rf "$STAGE" "$DIST"
mkdir -p "$STAGE" "$DIST"

# ---------------------------------------------------------------- helpers
control() {  # control <pkg> <arch> <section> <depends> <recommends> <suggests> <description>
    local pkg=$1 arch=$2 section=$3 dep=$4 rec=$5 sug=$6 desc=$7 root=$STAGE/$1
    mkdir -p "$root/DEBIAN"
    {
        echo "Package: $pkg"
        echo "Version: $VERSION"
        echo "Architecture: $arch"
        echo "Maintainer: $MAINTAINER"
        echo "Section: $section"
        echo "Priority: optional"
        echo "Installed-Size: $(du -sk --exclude=DEBIAN "$root" | cut -f1)"
        [[ -n $dep ]] && echo "Depends: $dep"
        [[ -n $rec ]] && echo "Recommends: $rec"
        [[ -n $sug ]] && echo "Suggests: $sug"
        echo "Homepage: $HOMEPAGE"
        printf 'Description: %s\n' "$desc"
    } > "$root/DEBIAN/control"
}
changelog() {  # changelog <pkg>
    local d=$STAGE/$1/usr/share/doc/$1
    mkdir -p "$d"
    printf '%s (%s) unstable; urgency=low\n\n  * Release %s.\n\n -- %s  %s\n' "$1" "$VERSION" "$VERSION" "$MAINTAINER" "$DATE_RFC" | gzip -9n > "$d/changelog.gz"
}
finish() {  # finish <pkg>: permissions, md5sums, build the .deb
    local pkg=$1 root=$STAGE/$1 arch
    arch=$(grep '^Architecture:' "$root/DEBIAN/control" | cut -d' ' -f2)
    find "$root" -type d -exec chmod 755 {} +
    find "$root" -type f -exec chmod 644 {} +
    find "$root$PREFIX/bin" "$root/usr/local/bin" -type f -exec chmod 755 {} + 2>/dev/null || true
    find "$root/DEBIAN" -type f \( -name postinst -o -name postrm \) -exec chmod 755 {} +
    (cd "$root" && find . -type f ! -path './DEBIAN/*' -printf '%P\0' | sort -z | xargs -0 md5sum > DEBIAN/md5sums)
    fakeroot dpkg-deb --root-owner-group -Zxz --build "$root" "$DIST/${pkg}_${VERSION}_${arch}.deb" >/dev/null
}
dep5_header() {
    printf 'Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/\nUpstream-Name: %s\nSource: %s\n\n' "$NAME" "$HOMEPAGE"
}

# ================================================================= package 1: the program
log "Staging $NAME"
P=$STAGE/$NAME
install -d "$P$PREFIX/bin" "$P$PREFIX/themes" "$P/usr/local/bin" "$P/usr/share/applications" \
           "$P/usr/share/icons/hicolor/scalable/apps" "$P/usr/share/doc/$NAME" "$P/usr/share/lintian/overrides" "$P/DEBIAN"
cp -r shell.qml qml docs examples README.md VERSION "$P$PREFIX/"
# Circle AI is a QML renderer plug-in, not a bitmap/sprite-art theme. Ship its
# manifest with the core so it is available immediately after installing
# revvy-ai, even when optional art theme packages are omitted.
for t in "${CORE_THEMES[@]}"; do cp -r "themes/$t" "$P$PREFIX/themes/"; done
[[ -f LICENSE ]] && cp LICENSE "$P$PREFIX/"
install -m755 "$BUILD/config-tool/revvy-ai-config" "$P$PREFIX/bin/revvy-ai-config"
strip --strip-unneeded "$P$PREFIX/bin/revvy-ai-config"
install -m755 scripts/revvy-ai "$P/usr/local/bin/revvy-ai"
sed "s|/opt/ttos/revvy-ai|$PREFIX|g" "$P/usr/local/bin/revvy-ai" > "$P/usr/local/bin/revvy-ai.tmp"
mv "$P/usr/local/bin/revvy-ai.tmp" "$P/usr/local/bin/revvy-ai"
cat > "$P/usr/local/bin/revvy-ai-config" <<SH
#!/usr/bin/env bash
exec $PREFIX/bin/revvy-ai-config "\$@"
SH
cat > "$P/usr/local/bin/revvy-ai-voice-trainer" <<SH
#!/usr/bin/env bash
exec $PREFIX/bin/revvy-ai-voice-trainer "\$@"
SH
chmod 755 "$P/usr/local/bin/revvy-ai" "$P/usr/local/bin/revvy-ai-config" "$P/usr/local/bin/revvy-ai-voice-trainer"
install -m755 scripts/revvy-ai-voice-listener "$P$PREFIX/bin/revvy-ai-voice-listener"
install -m755 scripts/revvy-ai-voice-listener.py "$P$PREFIX/bin/revvy-ai-voice-listener.py"
install -m755 scripts/revvy-ai-voice-trainer "$P$PREFIX/bin/revvy-ai-voice-trainer"
install -m755 scripts/revvy-ai-voice-trainer.py "$P$PREFIX/bin/revvy-ai-voice-trainer.py"
# Bundle the small offline Vosk model and only the Python modules it requires.
# This keeps speech recognition distributable instead of relying on a developer
# virtual environment or transmitting microphone audio to a network service.
install -d "$P$PREFIX/voice-python" "$P$PREFIX/voice-model"
python3 -m pip install --disable-pip-version-check --no-compile --no-cache-dir \
    --target "$P$PREFIX/voice-python" 'vosk==0.3.45' 'sounddevice==0.5.5'
if [[ -f "$VOSK_MODEL_ARCHIVE" ]]; then
    case "$VOSK_MODEL_ARCHIVE" in
        *.zip) unzip -q "$VOSK_MODEL_ARCHIVE" -d "$P$PREFIX/voice-model" ;;
        *) tar -xzf "$VOSK_MODEL_ARCHIVE" -C "$P$PREFIX/voice-model" ;;
    esac
else
    model_zip="$BUILD/${VOSK_MODEL_NAME}.zip"
    curl -fL --retry 3 "$VOSK_MODEL_URL" -o "$model_zip"
    unzip -q "$model_zip" -d "$P$PREFIX/voice-model"
fi
[[ -d "$P$PREFIX/voice-model/$VOSK_MODEL_NAME" ]] || { echo "ERROR: Vosk model staging failed" >&2; exit 1; }
install -d "$P/usr/lib/systemd/user"
install -m644 packaging/systemd/revvy-ai.service "$P/usr/lib/systemd/user/revvy-ai.service"
install -m644 packaging/systemd/revvy-ai-voice.service "$P/usr/lib/systemd/user/revvy-ai-voice.service"

cat > "$P/usr/share/applications/revvy-ai.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Revvy AI
GenericName=AI Desktop Assistant
Comment=Animated AI assistant that lives on your desktop
Exec=/usr/local/bin/revvy-ai
Icon=revvy-ai
Terminal=false
Categories=Utility;Qt;
Keywords=assistant;ai;chat;clippy;
StartupNotify=false
DESKTOP
cat > "$P/usr/share/applications/revvy-ai-config.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Revvy AI Settings
Comment=Configure the AI backend for Revvy AI
Exec=/usr/local/bin/revvy-ai-config
Icon=revvy-ai
Terminal=false
Categories=Settings;Qt;
DESKTOP
cat > "$P/usr/share/applications/revvy-ai-voice-trainer.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Revvy AI Voice Trainer
Comment=Calibrate Revvy AI's local voice recognition
Exec=/usr/local/bin/revvy-ai-voice-trainer
Icon=revvy-ai
Terminal=false
Categories=Settings;Utility;Qt;
Keywords=assistant;ai;voice;speech;training;
DESKTOP
cp tools/mascots/art/tux.svg "$P/usr/share/icons/hicolor/scalable/apps/revvy-ai.svg"

cat > "$P/usr/share/lintian/overrides/$NAME" <<OVERRIDES
# Installation under /opt/ttos and launchers in /usr/local/bin are deliberate (ttos layout).
$NAME: dir-or-file-in-opt *
$NAME: file-in-usr-local *
$NAME: dir-in-usr-local *
OVERRIDES

cat > "$P/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q /usr/share/applications || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
    # Do not globally enable either resident unit.  Revvy is a widget, and
    # its enabled state in ttos-widgetctl is the authoritative startup
    # decision.  Older packages did enable it globally, bypassing a disabled
    # widget after every login; remove those legacy global symlinks on upgrade.
    command -v systemctl >/dev/null 2>&1 && systemctl --global disable revvy-ai.service revvy-ai-voice.service >/dev/null 2>&1 || true
fi
exit 0
SH
sed 's/= configure/= remove/' "$P/DEBIAN/postinst" > "$P/DEBIAN/postrm"

{
    dep5_header
    cat <<COPYRIGHT
Files: *
Copyright: $YEAR $MAINTAINER
License: $PROJECT_LICENSE

Files: usr/share/icons/hicolor/scalable/apps/revvy-ai.svg
Copyright: Larry Ewing, Garrett LeSage, Simon Budig
License: Tux
 Tux was created by Larry Ewing with The GIMP; the SVG redraw is by Garrett LeSage and
 cleaned up by IFo Hancroft. Permission to use and/or modify is granted provided the
 artists are acknowledged.

License: GPL-3+
 On Debian systems, the full text of the GNU General Public License version 3
 can be found in /usr/share/common-licenses/GPL-3.
COPYRIGHT
} > "$P/usr/share/doc/$NAME/copyright"
cp README.md "$P/usr/share/doc/$NAME/README.md"
cp -r licenses "$P/usr/share/doc/$NAME/licenses"
changelog "$NAME"

SHLIBS=$(
    d=$(mktemp -d)
    mkdir "$d/debian"
    printf 'Source: x\n\nPackage: x\nArchitecture: any\n' > "$d/debian/control"
    (cd "$d" && dpkg-shlibdeps -O -e"$P$PREFIX/bin/revvy-ai-config" 2>/dev/null) | sed 's/^shlibs:Depends=//'
    rm -rf "$d"
)
control "$NAME" "$ARCH" utils \
    "quickshell, qml6-module-qtquick, qml6-module-qtquick-shapes, qml6-module-qtmultimedia, python3, python3-pyqt6, libportaudio2, pulseaudio-utils, revolution-weather, $NAME-themes-free (>= $VERSION), $SHLIBS" \
    "espeak-ng, xdg-utils" \
    "ollama, $NAME-themes-non-free (>= $VERSION)" \
    "Animated multi-backend AI desktop assistant (Quickshell/QML)
 A transparent animated character on your desktop that opens a speech bubble,
 asks an AI model (ChatGPT, Claude, Gemini, Grok, Meta Llama or a local model),
 types the answer into the bubble and speaks it aloud. It can fetch the weather
 and time, search the web and run terminal commands with your approval.
 Includes the revvy-ai-config settings utility.
 .
 Characters are provided by the revvy-ai-themes-free and
 revvy-ai-themes-non-free packages."
finish "$NAME"

# ================================================================= themes
stage_themes() {  # stage_themes <pkg> <themes...>
    local pkg=$1; shift
    local R=$STAGE/$pkg
    install -d "$R$PREFIX/themes" "$R/usr/share/doc/$pkg"
    for t in "$@"; do cp -r "themes/$t" "$R$PREFIX/themes/"; done
    cp themes/CREDITS.md "$R/usr/share/doc/$pkg/"
    cp README.md "$R/usr/share/doc/$pkg/README.md"
    cp -r licenses "$R/usr/share/doc/$pkg/licenses"
    install -d "$R/usr/share/lintian/overrides"
    printf '# Installation under /opt/ttos is deliberate (ttos layout).\n%s: dir-or-file-in-opt *\n' "$pkg" > "$R/usr/share/lintian/overrides/$pkg"
    changelog "$pkg"
}

log "Staging $NAME-themes-free"
stage_themes "$NAME-themes-free" "${FREE_THEMES[@]}"
{
    dep5_header
    cat <<COPYRIGHT
Files: opt/ttos/clippy-ai/themes/tux/*
Copyright: Larry Ewing, Garrett LeSage, Simon Budig
License: Tux

Files: opt/ttos/clippy-ai/themes/konqi/*
Copyright: Tyson Tan
License: CC-BY-SA-4.0

Files: opt/ttos/clippy-ai/themes/konqi-classic/*
Copyright: KDE artists (see Wikimedia Commons File:Konqi.svg)
License: GPL
 Distributed under the GNU General Public License; the source page does not state a version.
 See /usr/share/common-licenses/GPL.

Files: opt/ttos/clippy-ai/themes/wilber/*
Copyright: Matvizz
License: CC0-1.0

Files: opt/ttos/clippy-ai/themes/larry/*
Copyright: Ethan Dunham, Matteo Pescarin
License: CC-BY-SA-2.5
 https://creativecommons.org/licenses/by-sa/2.5/legalcode

Files: *
Copyright: $YEAR $MAINTAINER
Comment: Sprite sheets and animation data are generated by tools/mascots/build.py from the art above;
 they are derivative works under the same licences as the art they derive from.
License: $PROJECT_LICENSE

License: Tux
 Permission to use and/or modify the Tux image is granted provided the artists are acknowledged.
License: CC-BY-SA-4.0
 See /usr/share/common-licenses/CC-BY-SA-4.0.
License: CC0-1.0
 See /usr/share/common-licenses/CC0-1.0.
License: GPL-3+
 See /usr/share/common-licenses/GPL-3.
COPYRIGHT
} > "$STAGE/$NAME-themes-free/usr/share/doc/$NAME-themes-free/copyright"
control "$NAME-themes-free" all graphics "$NAME (>= $VERSION)" "" "" \
    "Free-licensed mascot characters for Revvy AI
 Tux, Konqi (new and classic), Wilber (GIMP) and Larry the Cow, animated as
 desktop assistant characters for Revvy AI. Tux is rigged from his layered
 SVG; the others are puppet-animated. Licences vary per character; see the
 copyright file."
finish "$NAME-themes-free"

if (( HAVE_NONFREE )); then
log "Staging $NAME-themes-non-free"
stage_themes "$NAME-themes-non-free" "${NONFREE_THEMES[@]}"
DOC=$STAGE/$NAME-themes-non-free/usr/share/doc/$NAME-themes-non-free
cp themes/LICENCE-pithings-clippy.js "$DOC/LICENSE-pithings-clippy.txt"
cp themes/LICENSE-modern-clippy.txt "$DOC/"
{
    dep5_header
    cat <<COPYRIGHT
Files: opt/ttos/clippy-ai/themes/*
Copyright: Microsoft Corporation (character artwork and sounds)
Comment: These are the Microsoft Agent characters (Clippit, Merlin, Bonzi, Genie, ...). They are
 NOT under a free licence. They reach us in converted form via the MIT-licensed projects
 pithings/clippy and vchaindz/modern-clippy (licences in this directory). Whether redistribution of
 the artwork is permitted has not been cleared; use for personal, non-commercial purposes.
License: Microsoft-Agent-characters
 No licence grant. Provided for personal, non-commercial use only.

Files: opt/ttos/clippy-ai/themes/*/agent.json
Copyright: 2012 Fireplace, Inc; 2017 Pooya Parsa; 2024 Dennis Zimmer, Codenotary, Inc.
Comment: Animation data converted from the MIT-licensed projects named above.
License: MIT
 See LICENSE-pithings-clippy.txt and LICENSE-modern-clippy.txt in this directory.
COPYRIGHT
} > "$DOC/copyright"
control "$NAME-themes-non-free" all non-free/graphics "$NAME (>= $VERSION)" "" "" \
    "Microsoft Agent characters for Revvy AI (non-free)
 Clippit, Merlin, Bonzi, Genie, Genius, F1, Links, Peedy, Rocky and Rover
 animated sprite sets with sound effects. The artwork is proprietary and has no
 free licence, so it is shipped separately from revvy-ai-themes-free."
finish "$NAME-themes-non-free"
fi

# ================================================================= report
log "Packages"
for f in "$DIST"/*.deb; do
    echo
    dpkg-deb -I "$f" | grep -E '^ (Package|Version|Architecture|Depends|Recommends|Section|Installed-Size)'
done
if command -v lintian >/dev/null; then
    log "lintian (informational)"
    lintian --profile debian --tag-display-limit 0 "$DIST"/*.deb || true   # explicit profile: a site-wide default profile may be missing
fi
log "Done: $(ls "$DIST" | tr '\n' ' ')"
