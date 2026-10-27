// The Mac front end's controller settings (controls_mac.m: Settings → Controllers…) and the players they move (front_mac.m). Main thread only, as GameController's handlers
#pragma once
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#include "dm_input.h"

// controls_mac.m
void controls_load(char players[DM_PLAYERS][64]);   // the saved settings; players: the controller name saved for each player ("" for none)
uint64_t controls_buttons(GCExtendedGamepad *g);    // the Switch buttons g presses through its type's map
void controls_sticks(GCExtendedGamepad *g, int32_t out[4]);   // left x, y, right x, y after the stick swap and the deadzone
void controls_seen(GCExtendedGamepad *g);           // every change of every controller, also out of focus: the window's live line and its "press a button" captures
void controls_install_menu(NSMenu *bar);            // the Settings menu, before the Window menu
void controls_pads_changed(void);                   // a controller connected or disconnected

// front_mac.m
GCController *pads_player(int p);                   // the controller of player p, nil for none
int pads_player_is_keyboard(int p);                 // player p is the keyboard's own (DM_KBD_PLAYER=own)
const char *pads_player_name(int p);                // the controller name kept for player p, also while it is away ("" for none)
int pads_merged(void);                              // DM_PAD_MERGE=1: every controller is player 1, players cannot be chosen
void pads_assign(GCController *c, int p);           // c becomes player p (a controller there swaps with it, or has no player when c had none)
void pads_unassign(int p);                          // player p's controller plays no player until assigned again or reconnected
void pads_reread(void);                             // read every controller again (a map changed)
const char *pad_name(GCController *c);
