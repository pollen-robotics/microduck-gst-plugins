#!/bin/sh
# Build the aarch64 GStreamer plugins the micro duck robot needs, from the pins in `pins.env`.
#
# Runs natively on aarch64 — in CI that is a `debian:trixie` container on an arm64 runner, which
# is what makes the output link against exactly the library versions the robot has rather than
# Ubuntu's or a cross sysroot's approximation of them. It also runs unchanged on a board, which
# is only useful for debugging: an RK3566 compiles the Rust half slowly enough that nobody should
# wait for it.
#
#   sudo sh scripts/build.sh              both plugins
#   sudo sh scripts/build.sh rockchip     just the MPP encoders
#   sudo sh scripts/build.sh webrtc       just webrtcsink/webrtcsrc
#
# Output lands in `dist/`: the .so files, SHA256SUMS, and MANIFEST recording which upstream commit
# each one came from. The manifest is not bookkeeping — it is the difference between a media bug
# somebody can reproduce and one they cannot, and it is what the third-party debs we rejected did
# not have.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${ROOT}/dist"
# Debian's own plugin directory for this arch, which is where the .so wants to *end up* on a
# robot's GST_PLUGIN_PATH. Built here into a prefix we own so nothing is installed system-wide by
# a build.
STAGE="${ROOT}/.stage"

# shellcheck disable=SC1091  # sibling file, in this repository.
. "${ROOT}/pins.env"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

WANT="${1:-both}"
case "$WANT" in
    both|rockchip|webrtc) ;;
    *) die "unknown target: ${WANT} (both, rockchip, webrtc)" ;;
esac

check_environment() {
    [ "$(id -u)" = 0 ] || die "run as root — it installs build dependencies"
    arch="$(uname -m)"
    [ "$arch" = aarch64 ] \
        || die "this builds natively for aarch64 and this is ${arch}.
  There is no cross-build here on purpose: linking against the robot's own Debian trixie
  libraries is the reason CI uses an arm64 runner in a debian:trixie container."
    command -v apt-get >/dev/null 2>&1 || die "expects a Debian userland"
}

apt_install() {
    missing=""
    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    [ -n "$missing" ] || return 0
    say "installing:$missing"
    apt-get update -qq
    # shellcheck disable=SC2086  # word-splitting the package list is the point
    apt-get install -y -qq --no-install-recommends $missing \
        || die "apt failed installing:$missing"
}

# Rockchip's MPP and RGA, from Radxa's pool, runtime and headers together.
#
# `dpkg -i` resolves nothing here — these are direct downloads, not a configured apt source — so
# the full closure is named and installed in one call. Learning that one package at a time cost
# three rounds on a board: `rockchip-mpp-demos` needs `librockchip-vpu0` at an exact version, and
# the GStreamer plugin needs `librga2`.
install_rockchip_userspace() {
    dpkg -s librockchip-mpp-dev >/dev/null 2>&1 && dpkg -s librga-dev >/dev/null 2>&1 && return 0

    tmp="$(mktemp -d)"
    # shellcheck disable=SC2064  # expand $tmp now, deliberately
    trap "rm -rf '$tmp'" EXIT INT TERM

    say "fetching Rockchip MPP ${MPP_VERSION} and RGA ${RGA_VERSION} from Radxa's pool"
    for path in \
        "m/mpp/librockchip-mpp1_${MPP_VERSION}_arm64.deb" \
        "m/mpp/librockchip-vpu0_${MPP_VERSION}_arm64.deb" \
        "m/mpp/librockchip-mpp-dev_${MPP_VERSION}_arm64.deb" \
        "libr/librga/librga2_${RGA_VERSION}_arm64.deb" \
        "libr/librga/librga-dev_${RGA_VERSION}_arm64.deb"
    do
        curl -fsSL -o "${tmp}/$(basename "$path")" "${RADXA_POOL}/${path}" \
            || die "cannot download ${RADXA_POOL}/${path}"
    done
    dpkg -i "${tmp}"/*.deb || die "dpkg -i failed on the Rockchip debs"
    rm -rf "$tmp"
    trap - EXIT INT TERM
}

build_rockchip() {
    apt_install meson ninja-build build-essential pkg-config git curl ca-certificates \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libdrm-dev libglib2.0-dev
    install_rockchip_userspace

    # Verified, because meson's answer to a missing MPP is not an error:
    # `gst/rockchipmpp/meson.build` ends in `if not mpp_dep.found() → subdir_done()`, so the whole
    # plugin is *silently skipped* and the build succeeds having produced nothing.
    for mod in rockchip_mpp librga; do
        pkg-config --exists "$mod" \
            || die "pkg-config cannot find ${mod}. meson skips the plugin silently without it,
  so this refuses here instead of shipping an empty release."
    done

    src="$(mktemp -d)"
    say "gstreamer-rockchip @ ${GST_ROCKCHIP_REF}"
    git clone -q --branch "$GST_ROCKCHIP_BRANCH" "$GST_ROCKCHIP_REPO" "${src}/s" \
        || die "cannot clone ${GST_ROCKCHIP_REPO}"
    # Reset to the pin: `--depth 1` alone would take whatever the branch tip is today, which is
    # the thing a pin exists to prevent.
    git -C "${src}/s" checkout -q "$GST_ROCKCHIP_REF" \
        || die "${GST_ROCKCHIP_REF} is not on ${GST_ROCKCHIP_BRANCH}"

    # `rkximage` and `kmssrc` are the X11 and KMS *sinks* in the same tree. A headless robot has
    # no use for either, and they are why the prebuilt Radxa deb depends on libx11-6. Dropping
    # them is the concrete thing building ourselves buys, beyond provenance.
    say "configuring (rockchipmpp only; X11 and KMS sinks disabled)"
    meson setup "${src}/b" "${src}/s" \
        --prefix /usr --libdir lib --buildtype release \
        -Drockchipmpp=enabled -Drga=enabled \
        -Drkximage=disabled -Dkmssrc=disabled -Dvpxalphadec=disabled \
        >"${src}/meson.log" 2>&1 || {
            tail -40 "${src}/meson.log" >&2
            die "meson setup failed; tail of its log above. The tree declares
  meson_version >= 0.47 and was written against a far older meson, so a syntax rejection is the
  failure to expect here. Installed: $(meson --version 2>/dev/null || echo unknown)."
        }
    ninja -C "${src}/b" >"${src}/ninja.log" 2>&1 || {
        tail -40 "${src}/ninja.log" >&2
        die "ninja failed; tail of its log above"
    }

    so="$(find "${src}/b" -name 'libgstrockchipmpp.so' -type f | head -1)"
    [ -n "$so" ] || die "no libgstrockchipmpp.so was produced.
  That is what a skipped subdir looks like rather than a compile error."

    install -d "$DIST"
    install -m 0644 "$so" "${DIST}/libgstrockchipmpp.so"
    strip --strip-unneeded "${DIST}/libgstrockchipmpp.so"
    printf 'libgstrockchipmpp.so %s %s\n' "$GST_ROCKCHIP_REPO" "$GST_ROCKCHIP_REF" \
        >> "${DIST}/MANIFEST"
    rm -rf "$src"
}

build_webrtc() {
    # `libgstreamer-plugins-bad1.0-dev` is the load-bearing one: it carries
    # `gstreamer-webrtc-1.0.pc` and `gstreamer-sdp-1.0.pc`, which is what the crate pkg-configs
    # against. Everything else is what a Rust cdylib needs to link.
    apt_install build-essential pkg-config git curl ca-certificates \
        libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev \
        libgstreamer-plugins-bad1.0-dev libssl-dev libglib2.0-dev

    # rustup rather than Debian's rustc. gst-plugins-rs tracks a recent toolchain and a distro
    # rustc that is a few months behind fails on an edition or a lint, months after anybody
    # remembers this choice was made.
    if ! command -v cargo >/dev/null 2>&1; then
        say "installing a Rust toolchain"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --profile minimal --default-toolchain stable >/dev/null \
            || die "rustup install failed"
    fi
    # shellcheck disable=SC1091  # written by rustup, just above.
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

    command -v cargo-cbuild >/dev/null 2>&1 || {
        say "installing cargo-c"
        cargo install cargo-c --locked >/dev/null || die "cargo install cargo-c failed"
    }

    src="$(mktemp -d)"
    say "gst-plugins-rs @ ${GST_PLUGINS_RS_REF}"
    git clone -q --depth 1 --branch "$GST_PLUGINS_RS_REF" "$GST_PLUGINS_RS_REPO" "${src}/s" \
        || die "cannot clone ${GST_PLUGINS_RS_REPO} at ${GST_PLUGINS_RS_REF}"

    # Our patches, applied in order and recorded in the MANIFEST. `--check` first so a patch that
    # no longer applies stops the build here, naming itself, rather than producing a plugin that is
    # quietly missing the change it was carried for.
    for patch in "${ROOT}"/patches/*.patch; do
        [ -e "$patch" ] || continue
        name="$(basename "$patch")"
        say "applying ${name}"
        ( cd "${src}/s" && git apply --check "$patch" ) \
            || die "${name} does not apply to ${GST_PLUGINS_RS_REF}.
  It was written against a specific version of the file it touches. Re-cut it against this ref, or
  drop it if upstream has taken the change — see patches/README.md."
        ( cd "${src}/s" && git apply "$patch" ) || die "${name} failed to apply"
        printf 'patch %s\n' "$name" >> "${DIST}/MANIFEST"
    done

    install -d "$DIST" "$STAGE"

    # Two crates, not one: the same stack wants `libgstrswebrtc.so` *and* `libgstrsrtp.so`.
    #
    # `gst-plugin-rtp`, whose lib is named `gstrsrtp` — the plugin filename and the crate name
    # differ, which is how the wrong one gets used. Pollen's reachy-mini-desktop-app README
    # documents `cargo cinstall -p gst-plugin-rsrtp`, and no such package exists in 0.14.5 or
    # 0.15.3; taking that name on trust cost a build. Read the crate's Cargo.toml, not a README.
    CRATES="gst-plugin-webrtc gst-plugin-rtp"

    # Checked before anything is compiled. `cargo cinstall` validates the package name only when
    # it gets to it, so a typo in the second crate is discovered after the first has spent three
    # minutes building — which is exactly what happened.
    bad=""
    for crate in $CRATES; do
        ( cd "${src}/s" && cargo pkgid -p "$crate" >/dev/null 2>&1 ) || bad="$bad $crate"
    done
    [ -z "$bad" ] || die "not workspace members of gst-plugins-rs ${GST_PLUGINS_RS_REF}:${bad}
  Package names move between releases. Check net/*/Cargo.toml at that tag."

    for crate in $CRATES; do
        say "cargo cinstall ${crate}"
        ( cd "${src}/s" && cargo cinstall -p "$crate" --prefix "$STAGE" --libdir lib --release ) \
            >"${src}/${crate}.log" 2>&1 || {
                tail -40 "${src}/${crate}.log" >&2
                die "${crate} failed to build; tail of its log above"
            }
    done

    found=0
    for so in "${STAGE}"/lib/gstreamer-1.0/*.so; do
        [ -e "$so" ] || continue
        found=1
        base="$(basename "$so")"
        install -m 0644 "$so" "${DIST}/${base}"
        strip --strip-unneeded "${DIST}/${base}"
        printf '%s %s %s\n' "$base" "$GST_PLUGINS_RS_REPO" "$GST_PLUGINS_RS_REF" \
            >> "${DIST}/MANIFEST"
    done
    [ "$found" = 1 ] || die "cargo cinstall produced no plugin under ${STAGE}/lib/gstreamer-1.0"
    rm -rf "$src" "$STAGE"
}

# What was built, and enough to verify it independently.
finish() {
    ( cd "$DIST" && rm -f SHA256SUMS && sha256sum ./*.so > SHA256SUMS )

    printf '\n'
    say "dist/"
    for f in "${DIST}"/*.so; do
        printf '  %-28s %8s bytes\n' "$(basename "$f")" "$(stat -c '%s' "$f")"
    done
    printf '\n'
    say "provenance"
    sed 's/^/  /' "${DIST}/MANIFEST"

    printf '\n'
    say "elements"
    # Loaded from dist/ exactly as a robot will load them, so this is the real question rather
    # than a proxy. `mpph264enc` may be missing here even when built: registration probes MPP, and
    # a container without /dev/mpp_service — or a robot whose node is still 0600 root:root —
    # cannot answer. Absence in CI is expected; absence on a board with the udev rule is not.
    for plug in rockchipmpp rswebrtc rsrtp; do
        GST_PLUGIN_PATH="$DIST" gst-inspect-1.0 "$plug" 2>/dev/null \
            | sed -n 's/^  \([a-z0-9]*\): /  \1  /p' || true
    done
    [ -e /dev/mpp_service ] || warn "no /dev/mpp_service here, so the MPP encoders cannot register
  in this environment. That is normal in CI: the .so still contains them, and a robot with the
  udev rule will see them. Verify there, not here."
}

main() {
    check_environment
    rm -rf "$DIST" && install -d "$DIST"
    : > "${DIST}/MANIFEST"
    case "$WANT" in
        rockchip) build_rockchip ;;
        webrtc)   build_webrtc ;;
        both)     build_rockchip; build_webrtc ;;
    esac
    apt_install gstreamer1.0-tools
    finish
}

# Called on the last line so a truncated download defines functions and then does nothing, rather
# than running half a build.
main "$@"
