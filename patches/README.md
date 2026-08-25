# Patches

Applied to the upstream checkout by `scripts/build.sh`, in filename order, and recorded in every
release's `MANIFEST` so a binary can be traced to the exact source that produced it.

**Carrying a patch is a cost, so each one has to say what it buys and how it ends.** A patch with no
route upstream is a fork with extra steps: it has to be re-cut at every version bump, and the
binary stops being something anyone else can reproduce from a public ref alone.

`build.sh` runs `git apply --check` first, so a patch that no longer applies fails the build naming
itself, rather than silently producing a plugin missing the change it was carried for.

---

## `0001-webrtcsink-no-converter-for-mpph264enc.patch`

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
