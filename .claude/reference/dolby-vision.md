# Dolby Vision: decisions on what goes on the cable

CLAUDE.md's rule applies here: PGenerator 1.6 is the gold standard wherever
a standard leaves room, PiTPG is not a reference, and where 1.6 departs
from a standard, the maintainer decides. This file holds the Dolby Vision
decisions taken so far, with who decided and when where that is recorded,
and the tests named with them.

## Decided exceptions to 1.6 (maintainer, 2026-11-17)

- In a Calman session the DV packet is Calman's own (with
  `signal_color_space` 0).
- The Standard DV infoframe follows the display's Dolby block (Amlogic's
  rule; 1.6 sends HDMI 1.4b with HDMI_VIC 1 in every timing when a client
  sets 1.6's dv_interface to 1, its kernel value for that layout; our
  conf's dv_interface 1 is Low Latency), with PiTPG's two departures from
  that rule kept (maintainer, 2026-11-09 and 2026-11-17):
  - a 12-byte version 1 block always gets the Dolby form;
  - 4K24/25/30 and 4096x2160p24 no HDMI_VIC.

## Standard DV packet

The Standard DV packet had taken over PiTPG's L4 block and start sequence,
which neither 1.6 nor Calman send; outside Calman and PiTPG sessions it
now sends 1.6's packet, checked against 1.6's templates by
`t/renderer_dovi_metadata.t` (ChadB, 2026-11-17).

## Metadata id

- 0 as 1.6, not stepping as ETSI 6.3.1 (the maintainer decides where 1.6
  departs from a standard).
- The metadata id is 0 in all three packet forms, PiTPG's included
  (2026-11-18).

## Tunnel codes and metadata pixels

- Outside PiTPG sessions the tunnel codes and the metadata pixels are
  1.6's: its matrix, 8-bit grid and packing, but
  - rounded exactly (integer arithmetic on the GPU, not 1.6's float32,
    which a CPU model of its shader puts one Cb/Cr code off for ~0.03 % of
    the colours; 1.6 on the GPU is not read back),
  - without 1.6's picture-path faults (fp16 texels 240..254, odd pixels
    paired with the next pair),
  - with exactly 3072 metadata pixels (1.6's stray white one left out).
- PiTPG sessions keep PiTPG's arithmetic and parity embedding, also for a
  first draw without an apply.
- The Pi 5 renderer flavour has the same pg16 shaders, byte for byte
  (`pg16_shaders` 1, maintainer 2026-11-23; not read back on a Pi 5; its
  PiTPG-session image shader is still its own).

## The WebUI's DV codes

The WebUI's DV series codes, and every patch it sends, lie on 1.6's 8-bit
grid whenever the cable carries that tunnel (`pg_dv_tunnel_pg16_grid`:
Standard in the running renderer's start record when it runs in Dolby
Vision, else the conf; no PiTPG packet, no full tunnel; the Patch
Companion gets the same codes), so a run records the code sent and a
grey's target follows it (maintainer, 2026-11-18). A colour's target stays
its reference colour, as at 8 bits in SDR, and a custom greyscale profile
keeps its targets.

Tests named with the tunnel and the WebUI's codes:
`t/renderer_pg16_tunnel.t`, `t/pitpg_backend.t`,
`t/webui_dv_tunnel_grid.t`, `t/meter_series_dv_tunnel_grid.t`,
`t/webui_dv_grid_chart_targets.t`, `t/meter_saturation_series_steps.t`.
