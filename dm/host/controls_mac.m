// Settings → Controllers… (⌘,): the Mac front end's controller settings, also while a game runs. Every change plays at once and is saved as a saved choice: a launcher.<VAR> value in the
// game app's preferences domain (its bundle ID), the store dm/mac/launcher.c reads (seedds/nxnative#386), so the next start gets it as that variable. DM_SAVED_CHOICES=0: this session only.
// - Buttons: what each button sends, one map for every controller: DM_PAD_MAP's (input_map.h), saved as launcher.DM_PAD_MAP. A button is mapped by pressing it.
//   As with the launcher, a DM_PAD_MAP the environment or env.txt sets wins at start over the saved one.
// - Face buttons: Automatic, By label or By position for all four (controls_map.h), saved as launcher.DM_PAD_ABXY; DM_PAD_ABXY=label|position in the environment wins the same way.
//   An explicit choice wins over the automatic detection (seedds/nxnative#295).
// - Per controller type (GCController.productCategory: "Xbox One", "Switch Pro Controller", …): a map and a face-button choice of its own, each used instead of the shared one only
//   where set, saved as controls.types. The launcher knows only the shared map; DM_PAD_MAP and DM_PAD_ABXY at launch replace only the shared ones.
// - Players: a controller becomes a player by pressing a button on it (front_mac.m pads_assign); the names are saved, so each takes its player back at the next start.
// - Sticks: swapped left and right, a radial deadzone.
// The previous version's controls.plist is imported only by its button.
#import "controls_mac.h"
#include "hle.h"
#include "controls_map.h"
#include "pad_apple.h"

// ---------- Settings ----------
static NSString *g_domain;          // the game app's bundle ID, as dm/mac/launcher.c's; nil for a host outside an app: nothing is saved
static int g_face;                  // PAD_FACE_*, the shared choice
static BOOL g_map_env, g_face_env, g_swap_sticks, g_save_failed;   // _env: the environment set it at start, and wins there over the saved choice
static float g_deadzone;            // 0 to 0.5 of full deflection
static NSString *const kFace = @"launcher.DM_PAD_ABXY", *const kSwap = @"controls.swapSticks", *const kDeadzone = @"controls.deadzone", *const kPlayers = @"controls.players",
                *const kTypes = @"controls.types";   // { type: { padMap: DM_PAD_MAP text, face: label | position | auto } }, each key only where the type has its own

// A controller type's own settings; face -1 and has_map NO: the shared ones
@interface DmTypeSettings : NSObject { @public pad_map map; BOOL has_map; int face; } @end
@implementation DmTypeSettings @end
static NSMutableDictionary<NSString *, DmTypeSettings *> *g_types;

static NSString *pad_type(GCController *c) { return c.productCategory ?: @""; }
static DmTypeSettings *type_of(NSString *t) { return t.length ? g_types[t] : nil; }
static DmTypeSettings *type_edit(NSString *t) {
    DmTypeSettings *o = g_types[t];
    if (!o) { o = [DmTypeSettings new]; o->face = -1; g_types[t] = o; }
    return o;
}
static void type_prune(NSString *t) { DmTypeSettings *o = type_of(t); if (o && !o->has_map && o->face < 0) [g_types removeObjectForKey:t]; }
const pad_map *controls_map(GCController *c) { DmTypeSettings *o = type_of(pad_type(c)); return o && o->has_map ? &o->map : pads_button_map(); }
static int face_of(GCController *c) { DmTypeSettings *o = type_of(pad_type(c)); return o && o->face >= 0 ? o->face : g_face; }

static BOOL saving(void) { const char *off = getenv("DM_SAVED_CHOICES"); return g_domain && !(off && !strcmp(off, "0")); }
static id saved(NSString *key) { return saving() ? CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)g_domain)) : nil; }
static void save(NSString *key, id value) {   // nil removes it
    if (!saving()) return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)g_domain);
    if (!CFPreferencesAppSynchronize((__bridge CFStringRef)g_domain)) { g_save_failed = YES; LOG("[RED] front end: controller setting %s not saved (it plays for this session)", key.UTF8String); }
}
static NSString *map_text(const pad_map *m) { char s[512]; pad_map_format(m, s, sizeof s); return @(s); }
static void save_map(void) { NSString *s = map_text(pads_button_map()); save(@"launcher.DM_PAD_MAP", s.length ? s : nil); }   // nil: the standard buttons, nothing saved
static void save_types(void) {
    NSMutableDictionary *d = [NSMutableDictionary new];
    [g_types enumerateKeysAndObjectsUsingBlock:^(NSString *t, DmTypeSettings *o, BOOL *stop) {
        NSMutableDictionary *e = [NSMutableDictionary new];
        if (o->has_map) e[@"padMap"] = map_text(&o->map);   // "" is a map of its own too: the standard buttons
        if (o->face >= 0) e[@"face"] = @(pad_face_name(o->face));
        if (e.count) d[t] = e;
    }];
    save(kTypes, d.count ? d : nil);
}
static void save_players(void) {
    NSMutableArray *names = [NSMutableArray new];
    for (int p = 0; p < DM_PLAYERS; p++) [names addObject:@(pads_player_name(p))];
    save(kPlayers, names);
}

// ---------- Reading a controller ----------
uint64_t controls_face(GCExtendedGamepad *g) {
    int face = face_of(g.controller);
    if (face == PAD_FACE_AUTO) return dm_pad_face(g);
    GCControllerButtonInput *a = g.buttonA, *b = g.buttonB, *x = g.buttonX, *y = g.buttonY;
    if (pad_face_swapped(face, dm_pad_labelled(g.controller))) { GCControllerButtonInput *t = a; a = b; b = t; t = x; x = y; y = t; }
    return (a.isPressed ? DM_BTN_A : 0) | (b.isPressed ? DM_BTN_B : 0) | (x.isPressed ? DM_BTN_X : 0) | (y.isPressed ? DM_BTN_Y : 0);
}
static void stick_read(GCControllerDirectionPad *d, int32_t *out) {
    float x = d.xAxis.value, y = d.yAxis.value;
    pad_deadzone(&x, &y, g_deadzone);
    out[0] = (int32_t)(fmaxf(-1.f, fminf(1.f, x)) * DM_STICK_MAX); out[1] = (int32_t)(fmaxf(-1.f, fminf(1.f, y)) * DM_STICK_MAX);
}
void controls_sticks(GCExtendedGamepad *g, int32_t out[4]) {
    stick_read(g_swap_sticks ? g.rightThumbstick : g.leftThumbstick, out);
    stick_read(g_swap_sticks ? g.leftThumbstick : g.rightThumbstick, out + 2);
}

// ---------- Labels ----------
// The element of g that presses button b before the map (pads_default_buttons), nil for one the pad lacks (stick presses, Options)
static GCControllerButtonInput *default_elem(GCExtendedGamepad *g, int b) {
    int sw = pad_face_swapped(face_of(g.controller), dm_pad_labelled(g.controller));
    switch (b) {
        case 0: return sw ? g.buttonB : g.buttonA;    case 1: return sw ? g.buttonA : g.buttonB;
        case 2: return sw ? g.buttonY : g.buttonX;    case 3: return sw ? g.buttonX : g.buttonY;
        case 4: return g.leftThumbstickButton;        case 5: return g.rightThumbstickButton;
        case 6: return g.leftShoulder;                case 7: return g.rightShoulder;
        case 8: return g.leftTrigger;                 case 9: return g.rightTrigger;
        case 10: return g.buttonMenu;                 case 11: return g.buttonOptions;
        case 12: return g.dpad.left;                  case 13: return g.dpad.up;
        case 14: return g.dpad.right;                 case 15: return g.dpad.down;
    }
    return nil;
}
static NSString *elem_name(GCController *c, int b, int face) {   // what the controller calls the button that presses b before the map ("B", "Button X", "L1"), a generic name without one
    static const char *const by_position[IM_BUTTONS] = { "Right face button", "Bottom face button", "Top face button", "Left face button", "Left stick press", "Right stick press",
                                                         "Left shoulder", "Right shoulder", "Left trigger", "Right trigger", "Menu", "Options", "D-pad left", "D-pad up", "D-pad right", "D-pad down" };
    NSString *n = c.extendedGamepad ? default_elem(c.extendedGamepad, b).localizedName : nil;
    if (n.length) return n;
    if (face == PAD_FACE_LABEL && b < 4) return [NSString stringWithFormat:@"Face button marked %s", im_names[b]];
    return @(by_position[b]);
}
static NSString *target_label(int to) {   // a Switch button as the window shows it
    static const char *const labels[IM_BUTTONS] = { "A", "B", "X", "Y", "Left stick press", "Right stick press", "L", "R", "ZL", "ZR", "+", "−", "D-pad left", "D-pad up", "D-pad right", "D-pad down" };
    return to < 0 ? @"nothing" : to < IM_BUTTONS ? @(labels[to]) : @"?";
}
static const int kTargets[] = { 0, 1, 2, 3, 6, 7, 8, 9, 10, 11, 4, 5, 13, 15, 12, 14 };   // the window's order, as the launcher's Controls page lists them
#define TARGETS ((int)(sizeof kTargets / sizeof *kTargets))

// ---------- Loading ----------
static int face_parse(id v, const char *what) {   // -1 for none
    if (![v isKindOfClass:NSString.class]) return -1;
    int f = pad_face_parse([v UTF8String]);
    if (f < 0) LOG("[RED] front end: face buttons '%s' (%s) is not auto, label or position: left out", [v UTF8String], what);
    return f;
}
void controls_load(char players[DM_PLAYERS][64]) {
    g_domain = NSBundle.mainBundle.bundleIdentifier;
    memset(players, 0, DM_PLAYERS * sizeof players[0]);
    // The buttons: DM_PAD_MAP, from the environment or (dm/mac/launcher.c) from the saved choice; a host the launcher did not start reads the saved choice itself
    pad_map *map = pads_button_map(); pad_map_default(map);
    const char *env = getenv("DM_PAD_MAP"); g_map_env = env && *env;
    id spec = g_map_env ? @(env) : saved(@"launcher.DM_PAD_MAP");
    if ([spec isKindOfClass:NSString.class] && [spec length]) {
        int bad = pad_map_parse(map, [spec UTF8String]);
        LOG("front end: controller buttons from %s (%s)%s", g_map_env ? "DM_PAD_MAP" : "the saved choice", [spec UTF8String], bad ? ", malformed entries left out" : "");
    }
    env = getenv("DM_PAD_ABXY"); g_face_env = env && *env;
    g_face = MAX(face_parse(g_face_env ? @(env) : saved(kFace), g_face_env ? "DM_PAD_ABXY" : "saved choice"), PAD_FACE_AUTO);
    if (g_face != PAD_FACE_AUTO) LOG("front end: face buttons by %s for every controller (%s)", pad_face_name(g_face), g_face_env ? "DM_PAD_ABXY" : "saved choice");
    g_types = [NSMutableDictionary new];
    NSDictionary *types = saved(kTypes);
    if ([types isKindOfClass:NSDictionary.class]) [types enumerateKeysAndObjectsUsingBlock:^(id t, id e, BOOL *stop) {
        if (![t isKindOfClass:NSString.class] || ![t length] || ![e isKindOfClass:NSDictionary.class]) return;
        DmTypeSettings *o = type_edit(t);
        if ([e[@"padMap"] isKindOfClass:NSString.class]) { pad_map_default(&o->map); pad_map_parse(&o->map, [e[@"padMap"] UTF8String]); o->has_map = YES; }
        o->face = face_parse(e[@"face"], [t UTF8String]);
        type_prune(t);
        if (g_types[t]) LOG("front end: %s: %s%s%s", [t UTF8String], o->has_map ? "its own buttons" : "", o->has_map && o->face >= 0 ? ", " : "", o->face >= 0 ? [[NSString stringWithFormat:@"face buttons by %s", pad_face_name(o->face)] UTF8String] : "");
    }];
    id swap = saved(kSwap), dz = saved(kDeadzone), names = saved(kPlayers);
    g_swap_sticks = [swap isKindOfClass:NSNumber.class] && [swap boolValue];
    g_deadzone = [dz isKindOfClass:NSNumber.class] ? fminf(0.5f, fmaxf(0.f, [dz floatValue])) : 0;
    for (NSUInteger p = 0; [names isKindOfClass:NSArray.class] && p < DM_PLAYERS && p < [names count]; p++)
        if ([names[p] isKindOfClass:NSString.class]) snprintf(players[p], sizeof players[p], "%s", [names[p] UTF8String]);
    if (!saving()) LOG("front end: controller settings for this session only (%s)", g_domain ? "DM_SAVED_CHOICES=0" : "no app bundle");
}

// ---------- The previous version's controls.plist ----------
// { version 1, defaultMap {element key: button key}, typeMaps {type: {…}}, swapSticks, deadzone, players [names] } in this game's folder (DM_ROOT) or the shared nxnative folder above it.
// Its elements are GameController's: an Xbox-style pad's face buttons by their letters, read by position; a Nintendo pad's by its own letters, which are its positions (pad_apple.h)
static NSString *legacy_path(void) {
    const char *root = getenv("DM_ROOT");
    NSString *game = root && *root ? @(root) : [NSHomeDirectory() stringByAppendingFormat:@"/Library/Application Support/nxnative/%016llX", (unsigned long long)dm_profile()->program_id];
    for (NSString *p in @[[game stringByAppendingPathComponent:@"controls.plist"], [game.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"controls.plist"]])
        if ([NSFileManager.defaultManager fileExistsAtPath:p]) return p;
    return nil;
}
static BOOL type_nintendo(NSString *t) { return [t isEqualToString:@"Switch Pro Controller"] || [t containsString:@"Joy-Con"]; }   // pad_apple.h dm_pad_labelled, by the type alone
static NSString *legacy_map(NSDictionary *old, BOOL nintendo) {   // an old map as DM_PAD_MAP text
    NSMutableDictionary *from = [@{ @"buttonA": @"B", @"buttonB": @"A", @"buttonX": @"Y", @"buttonY": @"X", @"leftShoulder": @"L", @"rightShoulder": @"R", @"leftTrigger": @"ZL", @"rightTrigger": @"ZR",
                                    @"buttonMenu": @"Plus", @"buttonOptions": @"Minus", @"leftStickPress": @"LS", @"rightStickPress": @"RS", @"dpadUp": @"Up", @"dpadDown": @"Down", @"dpadLeft": @"Left", @"dpadRight": @"Right" } mutableCopy];
    if (nintendo) [from addEntriesFromDictionary:@{ @"buttonA": @"A", @"buttonB": @"B", @"buttonX": @"X", @"buttonY": @"Y" }];
    NSDictionary *to = @{ @"LeftStick": @"LS", @"RightStick": @"RS", @"None": @"none" };
    NSMutableArray *entries = [NSMutableArray new];
    if ([old isKindOfClass:NSDictionary.class]) [old enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        if (from[k] && [v isKindOfClass:NSString.class] && ![from[k] isEqual:to[v] ?: v]) [entries addObject:[NSString stringWithFormat:@"%@=%@", from[k], to[v] ?: v]];
    }];
    return [entries componentsJoinedByString:@","];
}
static NSString *legacy_import(void) {   // nil when imported, else why not
    NSString *path = legacy_path();
    NSDictionary *d = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
    if (![d isKindOfClass:NSDictionary.class] || [d[@"version"] integerValue] != 1) return @"The previous settings could not be read.";
    pad_map *map = pads_button_map(); pad_map_default(map);
    NSString *spec = legacy_map(d[@"defaultMap"], NO);
    if (spec.length) pad_map_parse(map, spec.UTF8String);
    save_map();
    NSDictionary *types = d[@"typeMaps"];
    if ([types isKindOfClass:NSDictionary.class]) for (id t in types) if ([t isKindOfClass:NSString.class] && [t length]) {
        DmTypeSettings *o = type_edit(t); pad_map_default(&o->map); o->has_map = YES;
        NSString *s = legacy_map(types[t], type_nintendo(t));
        if (s.length) pad_map_parse(&o->map, s.UTF8String);
    }
    save_types();
    g_swap_sticks = [d[@"swapSticks"] boolValue]; save(kSwap, g_swap_sticks ? @YES : nil);
    g_deadzone = fminf(0.5f, fmaxf(0.f, [d[@"deadzone"] floatValue])); save(kDeadzone, g_deadzone > 0 ? @(g_deadzone) : nil);
    if ([d[@"players"] isKindOfClass:NSArray.class]) save(kPlayers, d[@"players"]);   // used at the next start, as reconnecting controllers take their players back
    LOG("front end: controller settings imported from %s", path.UTF8String);
    return nil;
}

// ---------- The window ----------
// Press…: the next button pressed on any controller (only one pressed after the click counts, not one already held) is mapped to a Switch button, or puts its controller on a player
typedef NS_ENUM(NSInteger, DmCapture) { DmCaptureNone, DmCaptureButton, DmCapturePlayer };

@interface DmControlsWindow : NSWindowController <NSWindowDelegate>
@end
@implementation DmControlsWindow {
    NSString *_type;          // what the face and button settings show: "" every controller (the shared ones), else a controller type
    NSGridView *_players, *_buttons;
    NSPopUpButton *_typeMenu, *_face;
    NSButton *_swap, *_standard, *_shared, *_import;
    NSSlider *_deadzone; NSTextField *_deadzoneValue, *_source, *_status;
    int _shownPlayers;
    DmCapture _capture; int _captureTarget, _capturePlayer;
    GCController *_example;   // the controller whose names the buttons show: the last one pressed of the type shown, else the first connected
    NSMapTable<GCController *, NSNumber *> *_heldAtCapture;
}

static NSTextField *label(NSString *s) { return [NSTextField labelWithString:s]; }
static NSTextField *heading(NSString *s) { NSTextField *t = label(s); t.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize]; return t; }
static NSTextField *note(NSString *s) { NSTextField *t = label(s); t.textColor = NSColor.secondaryLabelColor; t.lineBreakMode = NSLineBreakByTruncatingTail; [t.widthAnchor constraintEqualToConstant:600].active = YES; return t; }
static NSStackView *row(NSArray<NSView *> *views) { NSStackView *s = [NSStackView stackViewWithViews:views]; s.spacing = 8; return s; }

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:YES];
    w.title = @"Controllers"; w.releasedWhenClosed = NO;
    if (!(self = [super initWithWindow:w])) return nil;
    w.delegate = self; _type = @"";
    [self build];
    return self;
}
- (void)build {
    _players = [NSGridView gridViewWithViews:@[]]; _players.rowSpacing = 4; _players.columnSpacing = 8;
    _buttons = [NSGridView gridViewWithViews:@[]]; _buttons.rowSpacing = 4; _buttons.columnSpacing = 8;
    _typeMenu = [NSPopUpButton new]; _typeMenu.target = self; _typeMenu.action = @selector(typeChosen:);
    _face = [NSPopUpButton new]; _face.target = self; _face.action = @selector(faceChosen:);
    _standard = [NSButton buttonWithTitle:@"Standard Buttons" target:self action:@selector(standardButtons:)];
    _shared = [NSButton buttonWithTitle:@"Use the Settings for Every Controller" target:self action:@selector(useShared:)];
    _swap = [NSButton checkboxWithTitle:@"Swap left and right sticks" target:self action:@selector(swapChanged:)];
    _deadzone = [NSSlider sliderWithValue:0 minValue:0 maxValue:0.5 target:self action:@selector(deadzoneChanged:)];
    [_deadzone.widthAnchor constraintEqualToConstant:220].active = YES;
    _deadzoneValue = label(@"");
    _source = note(@""); _status = note(@"");
    _import = [NSButton buttonWithTitle:@"Import Previous Settings" target:self action:@selector(importPrevious:)];

    NSStackView *root = [NSStackView stackViewWithViews:@[
        heading(@"Players"), _players, [NSButton buttonWithTitle:@"Add Player" target:self action:@selector(addPlayer:)],
        row(@[heading(@"Controller"), _typeMenu, _shared]),
        row(@[label(@"Face buttons (A, B, X, Y)"), _face]),
        _source, _buttons, _standard,
        heading(@"Sticks"), _swap, row(@[label(@"Deadzone"), _deadzone, _deadzoneValue]),
        _status,
        row(@[[NSButton buttonWithTitle:@"Reset to Defaults" target:self action:@selector(resetToDefaults:)], _import]),
    ]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical; root.alignment = NSLayoutAttributeLeading; root.spacing = 10;
    root.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);
    self.window.contentView = root;
}

- (void)show {
    _capture = DmCaptureNone;
    [self reload]; [self note:nil];
    if (!self.window.visible) [self.window center];
    [self showWindow:nil];
}

// ---------- Contents ----------
- (GCController *)example {
    if ([GCController.controllers containsObject:_example] && (!_type.length || [pad_type(_example) isEqualToString:_type])) return _example;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad && (!_type.length || [pad_type(c) isEqualToString:_type])) return c;
    return nil;
}
// The map the buttons show and change: the type's own, made from the shared one on its first change, or the shared one
- (const pad_map *)shownMap { DmTypeSettings *o = type_of(_type); return o && o->has_map ? &o->map : pads_button_map(); }
- (pad_map *)editMap {
    if (!_type.length) return pads_button_map();
    DmTypeSettings *o = type_edit(_type);
    if (!o->has_map) { o->map = *pads_button_map(); o->has_map = YES; }
    return &o->map;
}
- (void)saveMap { if (_type.length) save_types(); else save_map(); }
- (int)shownFace { DmTypeSettings *o = type_of(_type); return o && o->face >= 0 ? o->face : g_face; }
- (void)reload {
    [self reloadPlayers]; [self reloadTypes]; [self reloadButtons];
    DmTypeSettings *o = type_of(_type);
    [_face removeAllItems];
    if (_type.length) [_face addItemWithTitle:[NSString stringWithFormat:@"As every controller (%@)", g_face == PAD_FACE_AUTO ? @"automatic" : @(pad_face_name(g_face))]];
    [_face addItemsWithTitles:@[@"Automatic", @"By label (the letter printed on each button)", @"By position (right A, bottom B, top X, left Y)"]];
    [_face selectItemAtIndex:_type.length ? (o ? o->face : -1) + 1 : g_face];
    _shared.hidden = !_type.length; _shared.enabled = o != nil;
    _swap.state = g_swap_sticks ? NSControlStateValueOn : NSControlStateValueOff;
    _deadzone.doubleValue = g_deadzone; _deadzoneValue.stringValue = [NSString stringWithFormat:@"%d%%", (int)lroundf(g_deadzone * 100)];
    pad_map d; pad_map_default(&d);
    _standard.enabled = !pad_map_equal([self shownMap], &d) || (_type.length && !(o && o->has_map));
    _import.hidden = legacy_path() == nil;
}
- (void)reloadTypes {
    NSMutableOrderedSet<NSString *> *types = [NSMutableOrderedSet new];
    for (GCController *c in GCController.controllers) if (c.extendedGamepad && pad_type(c).length) [types addObject:pad_type(c)];
    [types addObjectsFromArray:[g_types.allKeys sortedArrayUsingSelector:@selector(compare:)]];
    if (_type.length && ![types containsObject:_type]) _type = @"";
    [_typeMenu removeAllItems];
    [_typeMenu addItemWithTitle:@"Every controller"]; _typeMenu.lastItem.representedObject = @"";
    for (NSString *t in types) {
        DmTypeSettings *o = type_of(t);
        [_typeMenu addItemWithTitle:o ? [t stringByAppendingString:@" (own settings)"] : t]; _typeMenu.lastItem.representedObject = t;
    }
    [_typeMenu selectItemAtIndex:[_typeMenu indexOfItemWithRepresentedObject:_type]];
}
static void grid_clear(NSGridView *g) { while (g.numberOfRows) [g removeRowAtIndex:0]; }
- (void)reloadPlayers {
    grid_clear(_players);
    int used = 0; for (int p = 0; p < DM_PLAYERS; p++) if (pads_player(p) || pads_player_is_keyboard(p)) used = p + 1;
    _shownPlayers = MAX(MAX(_shownPlayers, used), 1);
    for (int p = 0; p < _shownPlayers; p++) {
        GCController *c = pads_player(p);
        NSString *who = c ? @(pad_name(c)) : pads_player_is_keyboard(p) ? @"Keyboard" : @"(empty)";
        NSButton *press = [NSButton buttonWithTitle:_capture == DmCapturePlayer && _capturePlayer == p ? @"Waiting…" : @"Press…" target:self action:@selector(pressForPlayer:)];
        NSButton *remove = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removePlayer:)];
        press.tag = remove.tag = p;
        press.enabled = !pads_merged() && !pads_player_is_keyboard(p); remove.enabled = c != nil;
        [_players addRowWithViews:@[heading([NSString stringWithFormat:@"Player %d", p + 1]), label(who), press, remove]];
    }
    if (pads_merged()) [_players addRowWithViews:@[label(@"Every controller is player 1 (DM_PAD_MERGE=1).")]];
}
- (void)reloadButtons {
    const pad_map *m = [self shownMap];
    NSString *s = map_text(m), *what = s.length ? [NSString stringWithFormat:@"DM_PAD_MAP=%@", s] : @"the standard buttons";
    DmTypeSettings *o = type_of(_type);
    if (!_type.length) {
        NSUInteger own = 0; for (DmTypeSettings *t in g_types.allValues) own += t->has_map;
        _source.stringValue = [NSString stringWithFormat:@"Every controller: %@%@%@", what,
                               own ? [NSString stringWithFormat:@" (%lu controller type%@ with buttons of their own)", (unsigned long)own, own == 1 ? @"" : @"s"] : @"",
                               g_map_env ? @". DM_PAD_MAP is also set at launch (environment or env.txt) and wins at the next start." : @"."];
    } else _source.stringValue = o && o->has_map ? [NSString stringWithFormat:@"%@: its own buttons, %@.", _type, what]
                                                 : [NSString stringWithFormat:@"%@: the buttons of every controller (%@). Pressing a button below gives it its own.", _type, what];
    grid_clear(_buttons);
    GCController *example = [self example]; int face = [self shownFace];
    int half = (TARGETS + 1) / 2;
    for (int r = 0; r < half; r++) {
        NSMutableArray *cells = [NSMutableArray new];
        for (int i = r; i < TARGETS; i += half) {   // two columns
            int t = kTargets[i];
            NSMutableArray *by = [NSMutableArray new];
            for (int b = 0; b < IM_BUTTONS; b++) if (m->to[b] == t) [by addObject:elem_name(example, b, face)];
            NSTextField *mapped = label(by.count ? [by componentsJoinedByString:@", "] : @"(none)");
            mapped.textColor = NSColor.secondaryLabelColor; mapped.lineBreakMode = NSLineBreakByTruncatingTail; mapped.toolTip = mapped.stringValue;
            [mapped.widthAnchor constraintEqualToConstant:150].active = YES;
            NSButton *press = [NSButton buttonWithTitle:_capture == DmCaptureButton && _captureTarget == t ? @"Waiting…" : @"Press…" target:self action:@selector(pressForButton:)];
            press.tag = t;
            [cells addObjectsFromArray:@[heading(target_label(t)), mapped, press]];
        }
        while (cells.count < 6) [cells addObject:NSGridCell.emptyContentView];
        [_buttons addRowWithViews:cells];
    }
}
- (void)note:(NSString *)s {
    if (s) { _status.stringValue = s; return; }
    _status.stringValue = g_save_failed ? @"Some changes could not be saved: they play for this session (see the game's log)."
                        : !saving() ? @"Changes play for this session only (DM_SAVED_CHOICES=0, or no app bundle)."
                        : @"Changes play at once and are saved. Press a button on a controller to see what it does.";
}
- (void)changed:(NSString *)s { pads_reread(); [self reload]; [self note:g_save_failed ? nil : s]; }

// ---------- Live line and captures (every controller change, controls_seen) ----------
- (void)seen:(GCExtendedGamepad *)g {
    uint32_t held = (uint32_t)(pads_default_buttons(g) & 0xffff);
    if (held && _example != g.controller && (!_type.length || [pad_type(g.controller) isEqualToString:_type])) {
        _example = g.controller; if (_capture == DmCaptureNone) [self reloadButtons];
    }
    if (_capture == DmCaptureNone) {
        NSMutableArray *on = [NSMutableArray new]; const pad_map *m = controls_map(g.controller);
        for (int b = 0; b < IM_BUTTONS; b++) if (held >> b & 1) [on addObject:[NSString stringWithFormat:@"%@ → %@", elem_name(g.controller, b, face_of(g.controller)), target_label(m->to[b])]];
        if (on.count) [self note:[NSString stringWithFormat:@"%s: %@", pad_name(g.controller), [on componentsJoinedByString:@", "]]];
        return;
    }
    uint32_t before = [_heldAtCapture objectForKey:g.controller].unsignedIntValue, fresh = held & ~before;
    [_heldAtCapture setObject:@(held & before) forKey:g.controller];   // a button let go counts once it is pressed again
    if (!fresh) return;
    int b = __builtin_ctz(fresh);
    DmCapture kind = _capture; _capture = DmCaptureNone;
    if (kind == DmCaptureButton) {
        pad_map_assign([self editMap], b, _captureTarget); [self saveMap];
        [self changed:[NSString stringWithFormat:@"%@ now presses %@ on %@.", elem_name(g.controller, b, face_of(g.controller)), target_label(_captureTarget),
                       _type.length ? [_type stringByAppendingString:@" controllers"] : @"every controller without buttons of its own"]];
    } else {
        pads_assign(g.controller, _capturePlayer); save_players();
        [self changed:[NSString stringWithFormat:@"%s is player %d.", pad_name(g.controller), _capturePlayer + 1]];
    }
}
- (void)startCapture:(DmCapture)kind {
    _capture = kind;
    _heldAtCapture = [NSMapTable weakToStrongObjectsMapTable];
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) [_heldAtCapture setObject:@((uint32_t)(pads_default_buttons(c.extendedGamepad) & 0xffff)) forKey:c];
    [self reload];
    [self note:kind == DmCaptureButton ? [NSString stringWithFormat:@"Press the controller button that should be %@… (Esc cancels)", target_label(_captureTarget)]
                                       : [NSString stringWithFormat:@"Press any button on the controller for player %d… (Esc cancels)", _capturePlayer + 1]];
}
- (void)cancelOperation:(id)sender { if (_capture != DmCaptureNone) { _capture = DmCaptureNone; [self reload]; [self note:nil]; } }

// ---------- Actions ----------
- (void)pressForButton:(NSButton *)b { _captureTarget = (int)b.tag; [self startCapture:DmCaptureButton]; }
- (void)pressForPlayer:(NSButton *)b { _capturePlayer = (int)b.tag; [self startCapture:DmCapturePlayer]; }
- (void)addPlayer:(id)sender { if (_shownPlayers < DM_PLAYERS) { _capturePlayer = _shownPlayers++; [self startCapture:DmCapturePlayer]; } }
- (void)removePlayer:(NSButton *)b { pads_unassign((int)b.tag); save_players(); [self changed:nil]; }
- (void)typeChosen:(NSPopUpButton *)m { _type = m.selectedItem.representedObject ?: @""; _capture = DmCaptureNone; [self reload]; [self note:nil]; }
- (void)faceChosen:(NSPopUpButton *)m {
    int i = (int)m.indexOfSelectedItem;
    if (_type.length) {   // item 0: as every controller
        type_edit(_type)->face = i - 1; type_prune(_type); save_types();
        LOG("front end: %s: face buttons %s", _type.UTF8String, i ? pad_face_name(i - 1) : "as every controller");
    } else {
        g_face = i; save(kFace, g_face == PAD_FACE_AUTO ? nil : @(pad_face_name(g_face)));
        LOG("front end: face buttons %s for every controller", pad_face_name(g_face));
    }
    [self changed:nil];
}
- (void)standardButtons:(id)sender { pad_map_default([self editMap]); [self saveMap]; [self changed:nil]; }
- (void)useShared:(id)sender {   // the type drops its own buttons and face choice
    [g_types removeObjectForKey:_type]; save_types();
    LOG("front end: %s: the settings of every controller", _type.UTF8String);
    [self changed:[NSString stringWithFormat:@"%@ uses the settings of every controller again.", _type]];
}
- (void)swapChanged:(NSButton *)b { g_swap_sticks = b.state == NSControlStateValueOn; save(kSwap, g_swap_sticks ? @YES : nil); [self changed:nil]; }
- (void)deadzoneChanged:(NSSlider *)s { g_deadzone = (float)s.doubleValue; save(kDeadzone, g_deadzone > 0 ? @(g_deadzone) : nil); [self changed:nil]; }
- (void)resetToDefaults:(id)sender {   // every controller's settings and every type's own
    pad_map_default(pads_button_map()); save_map();
    g_face = PAD_FACE_AUTO; save(kFace, nil);
    [g_types removeAllObjects]; save_types();
    g_swap_sticks = NO; save(kSwap, nil); g_deadzone = 0; save(kDeadzone, nil);
    _type = @"";
    [self changed:nil];
}
- (void)importPrevious:(id)sender {
    NSString *why = legacy_import();
    [self changed:why ?: @"Imported the previous settings. Players saved there take effect at the next start."];
}
@end

// ---------- Front end hooks (controls_mac.h) ----------
static DmControlsWindow *g_window;
void controls_seen(GCExtendedGamepad *g) { if (g_window.window.visible) [g_window seen:g]; }
void controls_pads_changed(void) { if (g_window.window.visible) [g_window reload]; }

@interface DmControlsMenu : NSObject @end
@implementation DmControlsMenu
- (void)open:(id)sender { if (!g_window) g_window = [DmControlsWindow new]; [g_window show]; }
@end
void controls_install_menu(NSMenu *bar) {
    static DmControlsMenu *target; target = [DmControlsMenu new];   // menu items hold their target weakly
    NSMenu *m = [[NSMenu alloc] initWithTitle:@"Settings"];
    [m addItemWithTitle:@"Controllers…" action:@selector(open:) keyEquivalent:@","].target = target;
    [[bar addItemWithTitle:@"Settings" action:nil keyEquivalent:@""] setSubmenu:m];
}
