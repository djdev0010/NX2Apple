// Controller button maps (controls_mac.m; pure, so tests/t_hid.c checks it without controllers): the Switch button each element of a physical controller presses.
// Elements are GameController's extended gamepad, which names the face buttons as an Xbox pad's (A bottom, B right, X left, Y top) whatever is printed on them.
// A map holds a Switch button mask per element (0: the element presses nothing), so a preset or a saved map never depends on the order of a table.
#pragma once
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "dm_input.h"

enum { PE_A, PE_B, PE_X, PE_Y, PE_LB, PE_RB, PE_LT, PE_RT, PE_MENU, PE_OPTIONS, PE_LSTICK, PE_RSTICK, PE_UP, PE_DOWN, PE_LEFT, PE_RIGHT, PE_N };
typedef struct { uint64_t to[PE_N]; } pad_map;

// Keys in controls.plist (stable: never shown) and the names shown when a controller gives an element none of its own
static const char *const pad_elem_key[PE_N] = { "buttonA", "buttonB", "buttonX", "buttonY", "leftShoulder", "rightShoulder", "leftTrigger", "rightTrigger",
                                                "buttonMenu", "buttonOptions", "leftStickPress", "rightStickPress", "dpadUp", "dpadDown", "dpadLeft", "dpadRight" };
static const char *const pad_elem_label[PE_N] = { "Bottom face button", "Right face button", "Left face button", "Top face button", "Left shoulder", "Right shoulder",
                                                  "Left trigger", "Right trigger", "Menu", "Options", "Left stick press", "Right stick press",
                                                  "D-pad up", "D-pad down", "D-pad left", "D-pad right" };

// The Switch buttons a map can press, in the order the settings window lists them
typedef struct { uint64_t bit; const char *key, *label; } pad_button;
static const pad_button pad_buttons[] = {
    {DM_BTN_A, "A", "A"}, {DM_BTN_B, "B", "B"}, {DM_BTN_X, "X", "X"}, {DM_BTN_Y, "Y", "Y"},
    {DM_BTN_L, "L", "L"}, {DM_BTN_R, "R", "R"}, {DM_BTN_ZL, "ZL", "ZL"}, {DM_BTN_ZR, "ZR", "ZR"},
    {DM_BTN_PLUS, "Plus", "+"}, {DM_BTN_MINUS, "Minus", "−"}, {DM_BTN_LS, "LeftStick", "Left stick press"}, {DM_BTN_RS, "RightStick", "Right stick press"},
    {DM_BTN_UP, "Up", "D-pad up"}, {DM_BTN_DOWN, "Down", "D-pad down"}, {DM_BTN_LEFT, "Left", "D-pad left"}, {DM_BTN_RIGHT, "Right", "D-pad right"},
};
#define PAD_BUTTONS ((int)(sizeof pad_buttons / sizeof pad_buttons[0]))

// By position, as on the Switch (and the iPhone's DmGamepad.m): right A, bottom B, top X, left Y. The front end's default, and a Nintendo controller's printed letters
static const pad_map PAD_MAP_POSITION = {{ DM_BTN_B, DM_BTN_A, DM_BTN_Y, DM_BTN_X, DM_BTN_L, DM_BTN_R, DM_BTN_ZL, DM_BTN_ZR,
                                           DM_BTN_PLUS, DM_BTN_MINUS, DM_BTN_LS, DM_BTN_RS, DM_BTN_UP, DM_BTN_DOWN, DM_BTN_LEFT, DM_BTN_RIGHT }};
// By the letters on an Xbox-style pad: the button marked A presses A (bottom A, right B, left X, top Y)
static const pad_map PAD_MAP_LETTERS = {{ DM_BTN_A, DM_BTN_B, DM_BTN_X, DM_BTN_Y, DM_BTN_L, DM_BTN_R, DM_BTN_ZL, DM_BTN_ZR,
                                          DM_BTN_PLUS, DM_BTN_MINUS, DM_BTN_LS, DM_BTN_RS, DM_BTN_UP, DM_BTN_DOWN, DM_BTN_LEFT, DM_BTN_RIGHT }};

static const pad_button *pad_button_of(uint64_t bit) {   // NULL for 0 (nothing) and for a bit no button has
    for (int i = 0; i < PAD_BUTTONS; i++) if (pad_buttons[i].bit == bit) return &pad_buttons[i];
    return 0;
}
// A saved button key: 1 and *bit set (0 for "None"), 0 for a key this version does not know (the caller keeps its value)
static int pad_button_parse(const char *key, uint64_t *bit) {
    if (!key) return 0;
    if (!strcmp(key, "None")) { *bit = 0; return 1; }
    for (int i = 0; i < PAD_BUTTONS; i++) if (!strcmp(pad_buttons[i].key, key)) { *bit = pad_buttons[i].bit; return 1; }
    return 0;
}
static int pad_elem_parse(const char *key) {   // -1 for an unknown key
    for (int e = 0; key && e < PE_N; e++) if (!strcmp(pad_elem_key[e], key)) return e;
    return -1;
}

// The Switch buttons pressed while the elements of `held` (bit e: element e) are down
static uint64_t pad_map_press(const pad_map *m, uint32_t held) {
    uint64_t b = 0;
    for (int e = 0; e < PE_N; e++) if (held >> e & 1) b |= m->to[e];
    return b;
}
// Element e presses `bit` from now on. The elements that pressed `bit` before take e's old button, so mapping by pressing swaps two buttons and never leaves one doing two jobs
static void pad_map_assign(pad_map *m, int e, uint64_t bit) {
    if (e < 0 || e >= PE_N) return;
    uint64_t old = m->to[e];
    for (int x = 0; bit && x < PE_N; x++) if (x != e && m->to[x] == bit) m->to[x] = old;
    m->to[e] = bit;
}
// Radial deadzone dz (0 to < 1): a deflection inside it reads as centered, the rest of the range is stretched to reach full deflection again
static void pad_deadzone(float *x, float *y, float dz) {
    float m = sqrtf(*x * *x + *y * *y);
    if (m <= dz) { *x = *y = 0; return; }
    if (dz <= 0) return;
    float k = fminf(1.f, (m - dz) / (1.f - dz)) / m;
    *x *= k; *y *= k;
}
