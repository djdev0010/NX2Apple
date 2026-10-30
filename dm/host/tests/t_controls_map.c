// The Mac controller settings window's map helpers (controls_map.h): mapping by pressing swaps, the map round-trips through DM_PAD_MAP text, the launcher's By label layout, the deadzone
#include <stdio.h>
#include "../controls_map.h"

static int checks, fails;
#define CHECK(c, what) do { checks++; if (!(c)) { fails++; printf("FAIL %s:%d %s\n", __FILE__, __LINE__, what); } } while (0)

static pad_map parsed(const char *s) { pad_map m; pad_map_default(&m); pad_map_parse(&m, s); return m; }

int main(void) {
    pad_map m, d; pad_map_default(&d);

    // Mapping by pressing swaps: the button that sent the target before takes the pressed button's old one
    m = d; pad_map_assign(&m, 1, 0);   // B sends A; A takes B
    CHECK(m.to[1] == 0 && m.to[0] == 1, "B pressed for A swaps A and B");
    pad_map_assign(&m, 8, -1);
    CHECK(m.to[8] == -1 && pad_map_apply(&m, DM_BTN_ZL) == 0, "a button can send nothing");
    pad_map_assign(&m, 9, -1);
    CHECK(m.to[9] == -1 && m.to[8] == -1, "a second button sending nothing leaves the first so");
    pad_map_assign(&m, 8, 9);
    CHECK(m.to[8] == 9 && m.to[9] == -1, "ZL sends ZR; ZR, which sent nothing, still does");
    pad_map tmp = m; pad_map_assign(&m, IM_BUTTONS, 0); pad_map_assign(&m, 0, IM_BUTTONS);
    CHECK(pad_map_equal(&m, &tmp), "out-of-range buttons change nothing");

    // DM_PAD_MAP text round-trips onto the default map
    char s[256];
    CHECK(pad_map_format(&d, s, sizeof s) && !strcmp(s, ""), "the default map is empty text");
    CHECK(pad_map_format(&m, s, sizeof s) && !strcmp(s, "A=B,B=A,ZL=ZR,ZR=none"), "a changed map formats as its changes, in input_map.h's order");
    pad_map back = parsed(s);
    CHECK(pad_map_equal(&back, &m), "and parses back to the same map");
    CHECK(pad_map_format(&m, s, 4) == 0 && s[0] == 0, "too small a buffer gives no text");

    // The launcher's By label layout
    pad_map_letters(&m);
    CHECK(pad_map_format(&m, s, sizeof s) && !strcmp(s, "A=B,B=A,X=Y,Y=X"), "By label is A=B,B=A,X=Y,Y=X, as the launcher passes it");
    CHECK(pad_map_apply(&m, DM_BTN_A | DM_BTN_L) == (DM_BTN_B | DM_BTN_L), "it swaps the face buttons only");

    // The face-button choice: label never swaps, position swaps all four on every pad but a Nintendo one, Automatic is dm_pad_face's (by position)
    CHECK(pad_face_parse(NULL) == PAD_FACE_AUTO && pad_face_parse("Label") == PAD_FACE_LABEL && pad_face_parse("position") == PAD_FACE_POSITION && pad_face_parse("letters") == -1, "DM_PAD_ABXY parses");
    for (int f = PAD_FACE_AUTO; f <= PAD_FACE_POSITION; f++) CHECK(pad_face_parse(pad_face_name(f)) == f, "a choice round-trips through its saved name");
    CHECK(!pad_face_swapped(PAD_FACE_LABEL, 0) && !pad_face_swapped(PAD_FACE_LABEL, 1), "by label: the button marked A is A on every pad");
    CHECK(pad_face_swapped(PAD_FACE_POSITION, 0) && !pad_face_swapped(PAD_FACE_POSITION, 1), "by position: an Xbox-style pad swaps, a Nintendo pad's letters are its positions");
    CHECK(pad_face_swapped(PAD_FACE_AUTO, 0) == pad_face_swapped(PAD_FACE_POSITION, 0) && pad_face_swapped(PAD_FACE_AUTO, 1) == pad_face_swapped(PAD_FACE_POSITION, 1), "Automatic reads as dm_pad_face does");

    // Deadzone: inside it centered, at full deflection still full, between stretched
    float x = 0.1f, y = 0.1f; pad_deadzone(&x, &y, 0.2f);
    CHECK(x == 0 && y == 0, "a deflection inside the deadzone is centered");
    x = 1, y = 0; pad_deadzone(&x, &y, 0.2f);
    CHECK(fabsf(x - 1) < 1e-6f && y == 0, "full deflection stays full");
    x = 0.6f, y = 0; pad_deadzone(&x, &y, 0.2f);
    CHECK(fabsf(x - 0.5f) < 1e-6f, "halfway between the deadzone and the edge reads as half");
    x = 0.3f, y = -0.4f; pad_deadzone(&x, &y, 0);
    CHECK(x == 0.3f && y == -0.4f, "no deadzone leaves the stick alone");

    printf("t_controls_map: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
