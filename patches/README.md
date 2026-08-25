# Patches

One directory per upstream — `gst-plugins-rs/`, `gstreamer-rockchip/` — applied to that
project's checkout by `scripts/build.sh` in filename order, and recorded in every release's
`MANIFEST` as `patch <project>/<file>` so a binary can be traced to the exact source that
produced it.

The routing is explicit rather than glob-everything, because a patch aimed at the wrong tree fails
the same way a stale one does, and the two want different fixes.

**Carrying a patch is a cost, so each one has to say what it buys and how it ends.** A patch with no
route upstream is a fork with extra steps: it has to be re-cut at every version bump, and the
binary stops being something anyone else can reproduce from a public ref alone.

`build.sh` runs `git apply --check` first, so a patch that no longer applies fails the build naming
itself, rather than silently producing a plugin missing the change it was carried for.

---

## `gst-plugins-rs/0001-webrtcsink-no-converter-for-mpph264enc.patch`

**What it changes.** `make_converter_for_video_caps` in `net/webrtc/src/webrtcsink/imp.rs` builds
the chain `webrtcsink` inserts in front of an encoder it selected. It special-cases hardware it
knows — NVMM, D3D11, CUDA, GL, VA, and on `main` also `v4l2h264enc` — and falls back to software
`videoconvert ! videoscale` for anything else. This adds an arm for `mpph264enc` that inserts
nothing.

**Why.** Rockchip's MPP encoder takes NV12, I420, YUY2 and more directly, and converts on the SoC's
2D accelerator rather than the CPU. A software convert-and-scale pass in front of it costs a full
CPU traversal of every frame on four Cortex-A55s — which is exactly what the hardware encoder is
there to avoid, and which shares those cores with `robotd`'s 50 Hz control loop.

**Why not just keep pre-encoding.** Because the robot did, and it costs more than it looks.
Handing `webrtcsink` finished H.264 means it cannot reach the encoder, so two things it normally
does silently do not happen: congestion control cannot adapt the bitrate to the link, and a peer's
PLI cannot produce a keyframe — a viewer that loses one stays broken until the next periodic GOP.
Letting `webrtcsink` own the encoder fixes both, and this patch is what makes that affordable here.

**The trade-off it makes.** Without `videoscale` the bin cannot resize, so the negotiated
resolution has to be one the source already produces. True on this robot, which pins its caps
upstream of its tee — and the honest reason this may need discussion before upstream takes it, since
a general fix would want RGA-backed scaling rather than none. `mpph264enc` has `width` and `height`
properties that scale on the VPU, but nothing in `webrtcsink` sets them.

**How it ends.** Upstream. The `v4l2h264enc` arm on `main` is the same shape for another hardware
encoder, so the precedent exists; if it is taken, this file is deleted at the next version bump.
Until then it is re-cut per bump, which `--check` will demand rather than let slide.

---

## `gstreamer-rockchip/0001-mpph264enc-advertise-constrained-baseline.patch`

**What it changes.** One word in `mpph264enc`'s src pad template: its profile list was
`{ baseline, main, high }` and is now `{ constrained-baseline, baseline, main, high }`.

**Why.** Without it `webrtcsink` cannot offer H.264 on this SoC at all, and says so only at
`GST_DEBUG=*:WARNING`. Its codec discovery pass builds the encoding chain with no output caps, so
`force_profile` is true and it inserts a capsfilter demanding
`video/x-h264, stream-format=avc, profile=constrained-baseline` — WebRTC's interoperable floor.
`h264parse` strips `alignment`, `stream-format` and `parsed` from a caps query but **not
`profile`**, so that demand reaches the encoder's src pad, whose template could not satisfy it.
The intersection is empty, `GstVideoEncoder`'s sink getcaps returns nothing, and the failure
surfaces far upstream as `videorate` reporting it "could not transform NV12 … in anything we
support". Discovery then drops H.264 with a warning, VP8 is negotiated instead, and the session
dies in `rtpvp8pay`. Nothing in the error names the profile.

**Why it is true and not a convenient claim.** `mpph264enc profile=baseline` sets `h264:cabac_en`
and the 8x8-transform flag off, and MPP emits no FMO, ASO or redundant slices — so the SPS it
writes really does carry `profile_idc=66` with `constraint_set1_flag`. Measured on an RK3566
rather than reasoned about: `videotestsrc ! mpph264enc profile=baseline ! h264parse` negotiates
`profile=(string)constrained-baseline` on the parser's src pad. The element could always produce
this; only its template denied it. A pad template is a capability set, not current state — the
same template already advertises all three other profiles regardless of which one the property
selects.

**The trade-off it makes.** None that we can find, which is itself worth stating: the change only
widens what the pad may agree to, and the encoder's own src caps still come from its `profile`
property. A pipeline that asked for `baseline` before still gets it.

**How it ends.** Upstream, at `JeffyCN/mirrors` or whichever Rockchip tree succeeds it. It is a
one-word capability fix with a reproducer, which is the easiest kind to land; if it is taken, this
file is deleted at the next pin bump. Until then `--check` demands it be re-cut per bump.
