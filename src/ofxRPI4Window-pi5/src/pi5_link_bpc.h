/* The "max bpc" the Pi 5 flavour writes on the HDMI connector.
 *
 * On the Pi 4, drm_override.so (LD_PRELOAD) replaces every "max bpc" the
 * renderer puts in an atomic request with the configured link depth
 * (usr/lib/drm_override.c override_max_bpc: max_bpc_override when it is
 * above 0). The Pi 5 starts the renderer without that library (the daemon's
 * "Colorspace-based kernel detected" path), so the renderer's own value
 * reached the kernel: avi_info.max_bpc, which follows the renderer's
 * bit_depth (8 with the 8-bit surface set up at a start, until a 10-bit
 * pattern arrives). A Pi 5 configured for 10 bits then sent 8 (issue #45:
 * 5 of 13 modes of a 4K24 self-test read an 8-bit link at the switch, each
 * after a restart or after a mode that drew no window).
 *
 * wire_bpc is the depth drm_override.so would write: main.cpp
 * applySignalConf computes it from the conf with the same promotions
 * (YCbCr 4:2:2 at least 10, 12 only in Dolby Vision, Standard Dolby Vision
 * 8) and again on every in-place reload. So the Pi 5 link follows the
 * configuration as the Pi 4 link does; an 8-bit surface goes out on the
 * deeper link, as there. Without a configured depth (wire_bpc 0: an empty
 * max_bpc value, where drm_override.so writes nothing; a missing line is
 * "8" to the renderer) the renderer's value stays. */
#ifndef PI5_LINK_BPC_H
#define PI5_LINK_BPC_H

#include <stdint.h>

static inline uint64_t pi5_connector_max_bpc(int wire_bpc, uint64_t renderer_bpc)
{
	if (wire_bpc > 0)
		return (uint64_t)wire_bpc;
	return renderer_bpc;
}

#endif
