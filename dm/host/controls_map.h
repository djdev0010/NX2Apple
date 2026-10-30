// The controller settings window's map helpers (controls_mac.m; pure, so tests/t_controls_map.c checks them without controllers). The map is input_map.h's pad_map, the one
// DM_PAD_MAP fills at start: for each button the default reading sends (pad_apple.h dm_pad_face: by position, a Nintendo pad by its labels), the button it sends instead.
#pragma once
#include <math.h>
#include "input_map.h"

// The launcher's "By label" layout (frontend ControlPresets.swift byLabelPad): an Xbox-style pad's printed letters, A and B swapped, X and Y swapped
static void pad_map_letters(pad_map *m) {
    pad_map_default(m);
    m->to[0] = 1; m->to[1] = 0; m->to[2] = 3; m->to[3] = 2;
}
static int pad_map_equal(const pad_map *a, const pad_map *b) { return !memcmp(a->to, b->to, sizeof a->to); }

// Button `from` sends `to` from now on (-1: nothing). The button that sent `to` before takes from's old one, so mapping by pressing swaps two buttons and never leaves one doing two jobs
static void pad_map_assign(pad_map *m, int from, int to) {
    if (from < 0 || from >= IM_BUTTONS || to < -1 || to >= IM_BUTTONS) return;
    int old = m->to[from];
    for (int b = 0; to >= 0 && b < IM_BUTTONS; b++) if (b != from && m->to[b] == to) m->to[b] = (int8_t)old;
    m->to[from] = (int8_t)to;
}

// m as DM_PAD_MAP text, only the buttons that send another ("" for the default map), so pad_map_parse onto the default map gives m back. 0 when cap is too small
static int pad_map_format(const pad_map *m, char *out, size_t cap) {
    size_t n = 0; if (!cap) return 0;
    out[0] = 0;
    for (int b = 0; b < IM_BUTTONS; b++) if (m->to[b] != b) {
        int w = snprintf(out + n, cap - n, "%s%s=%s", n ? "," : "", im_names[b], m->to[b] < 0 ? "none" : im_names[m->to[b]]);
        if (w < 0 || (size_t)w >= cap - n) { out[0] = 0; return 0; }
        n += (size_t)w;
    }
    return 1;
}

// The four face buttons (A/B and X/Y together): Automatic (pad_apple.h dm_pad_face), or by the letter printed on each or by position for every controller, whatever it is detected as.
// A choice wins over the automatic one (seedds/nxnative#295's DM_PAD_ABXY=label|position). GameController names an Xbox-style pad's face buttons by their letters (A bottom, B right)
// and a Nintendo pad's by its own (A right), so reading by position swaps A/B and X/Y on every pad but a Nintendo one, and reading by label swaps none
enum { PAD_FACE_AUTO, PAD_FACE_LABEL, PAD_FACE_POSITION };
static int pad_face_parse(const char *s) {   // -1 for a value that is none of them (the caller keeps Automatic)
    if (!s || !*s || !strcasecmp(s, "auto")) return PAD_FACE_AUTO;
    return !strcasecmp(s, "label") ? PAD_FACE_LABEL : !strcasecmp(s, "position") ? PAD_FACE_POSITION : -1;
}
static const char *pad_face_name(int face) { return face == PAD_FACE_LABEL ? "label" : face == PAD_FACE_POSITION ? "position" : "auto"; }
static int pad_face_swapped(int face, int nintendo) { return face == PAD_FACE_LABEL ? 0 : !nintendo; }   // Automatic reads by position today (dm_pad_face)

// Radial deadzone dz (0 to < 1): a deflection inside it reads as centered, the rest of the range is stretched to reach full deflection again
static void pad_deadzone(float *x, float *y, float dz) {
    float m = sqrtf(*x * *x + *y * *y);
    if (m <= dz) { *x = *y = 0; return; }
    if (dz <= 0) return;
    float k = fminf(1.f, (m - dz) / (1.f - dz)) / m;
    *x *= k; *y *= k;
}
