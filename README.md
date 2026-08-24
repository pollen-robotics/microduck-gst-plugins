# microduck-gst-plugins

Prebuilt aarch64 GStreamer plugins for the micro duck robot, built in CI from pinned upstream
sources and attached to a release.

Two plugins, for two unrelated reasons. Neither is packaged anywhere we can install from.

| plugin | provides | why it is here |
|---|---|---|
| `libgstrockchipmpp.so` | `mpph264enc`, `mpph265enc`, `mppjpegenc`, `mppvp8enc`, `mppvideodec`, `mppjpegdec` | Debian ships no Rockchip encoder in any suite, and Radxa's `gstreamer1.0-rockchip1_1.14-4` is **decode-only** — measured on a Zero 3W: `mppvideodec` and `mppjpegdec`, nothing else. 1.14.4 predates the encoders. |
| `libgstrswebrtc.so`, `libgstrsrtp.so` | `webrtcsink`, `webrtcsrc`, `rsrtp*` | `gstreamer1.0-plugins-rs` does not exist in **any** Debian suite — not trixie, backports, sid or experimental. |

`webrtcbin` is **not** here: it comes from `gstreamer1.0-plugins-bad` in Debian and needs no
build.

## Why a repository of its own

The robot's daemon is cross-compiled from a developer's machine with `cargo-zigbuild`, and its one
C dependency is already the documented cost of doing that. GStreamer would be a much larger second
one — a cross sysroot or x86 multiarch, either of which links against an approximation of the
target.

So these are built **natively on an arm64 runner, in a `debian:trixie` container**, which is the
robot's own userland. Nothing is cross-compiled and nothing is approximated. arm64 runners are
free on public repositories, which is one reason this repository is public.

The other reason matters more: a release asset here is fetched by a robot during provisioning and
by the updater's `preinstall` hook, and that hook runs with a cleared environment and no token. A
private repository would break it. This is the same arrangement the daemon already relies on for
ONNX Runtime, which comes from a public `microsoft/onnxruntime` release.

Building rather than taking a third-party binary also buys one concrete thing beyond provenance:
`rkximage` and `kmssrc`, the X11 and KMS *sinks* in the same source tree, are **disabled**. A
headless robot has no use for either, and they are why the prebuilt Radxa deb depends on
`libx11-6`.

## Consuming a release

```
tar -xzf microduck-gst-plugins-<version>-aarch64.tar.gz
```

Put the `.so` files anywhere and point `GST_PLUGIN_PATH` at it — `/usr/local/lib/gstreamer-1.0`
on a robot, which is deliberately **not** the distro's plugin directory, so an `apt` operation can
never quietly replace or remove them.

```
GST_PLUGIN_PATH=/usr/local/lib/gstreamer-1.0 gst-inspect-1.0 mpph264enc
```

Verify the tarball against the `.sha256` beside it before unpacking. **Pin a version**; do not
follow "latest". Two provisioning runs a day apart that produce different plugins, with nothing
recording which, is an unreproducible media bug waiting to happen.

### Runtime dependencies

The plugins link against libraries a robot needs installed:

- `librockchip-mpp1` and `librga2` — from Radxa's pool, at the versions in
  [`pins.env`](pins.env). Not in Debian.
- `libgstreamer1.0-0`, `libgstreamer-plugins-base1.0-0`, `libglib2.0-0`, `libdrm2` — Debian.

`mpph264enc` also needs **read/write access to `/dev/mpp_service`**, which arrives as `0600
root:root`. The failure that causes is silent in two different ways: `mpi_enc_test` writes an empty
file and exits 0, and this plugin registers its *decoders* while omitting the *encoders*, because
registration probes MPP. A non-root process needs a udev rule giving the node a group.

## Bumping a pin

Edit [`pins.env`](pins.env), commit, tag `vN`, push the tag. The release workflow builds and
attaches the tarball, with the manifest as the release notes so a release always says which
upstream commits it came from.

`workflow_dispatch` builds without cutting a release — worth using, because a workflow that only
ever runs on a tag is one you discover is broken at the moment you need it.

## Licences and source

These are binaries built from other people's source, so where that source is matters:

- **`gstreamer-rockchip`** is LGPL. Built from
  [`JeffyCN/mirrors`](https://github.com/JeffyCN/mirrors) on the `gstreamer-rockchip` branch, at
  the commit in `pins.env` and recorded in every release's `MANIFEST`.
  `rockchip-linux/gstreamer-rockchip`, which every published deb names as its homepage, is a 404;
  `JeffyCN/mirrors` is the live mirror under the same maintainer.
- **`gst-plugins-rs`** is MPL-2.0. Built from
  [the upstream repository](https://gitlab.freedesktop.org/gstreamer/gst-plugins-rs) at the tag in
  `pins.env`.

Nothing here is modified — no patches, no forks. Each release's `MANIFEST` names the repository
and the exact ref per plugin, which is both the licence answer and the reason a media bug found on
a robot can be traced to a specific build.

This repository's own build scripts are Apache-2.0, matching the daemon.
