#pragma once
#include "sub/osd.h"
struct mpv_global;
bool GPMPVHasSecondaryASS(struct mpv_global *global, int order);
void GPMPVTransformSecondaryASS(struct mpv_global *global, int order, const void *decoder,
                               struct mp_osd_res dim, struct sub_bitmaps *parts);

bool GPMPVMirrorsPrimaryASS(struct mpv_global *global);
