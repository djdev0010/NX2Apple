// Settings → Controllers… (⌘,): the Mac front end's controller settings, also while a game runs.
// - Buttons: a map per controller type (GCController.productCategory: "Switch Pro Controller", "Xbox One", ...), so each kind can follow the letters printed on it; a type without
//   a map of its own uses the default map (by position, as before the settings existed: pad_map.h PAD_MAP_POSITION). A button is mapped by pressing it.
// - Players: a controller becomes a player by pressing a button on it (front_mac.m pads_assign); the names are saved, so each takes its player back at the next start.
// - Sticks: swapped left and right, a radial deadzone.
// Changes act at once; Save writes controls.plist, shared by every game in the nxnative folder, or this game's own in its folder (DM_ROOT), which wins when it exists.
#import "controls_mac.h"
#include "hle.h"
#include "pad_map.h"

// ---------- Settings ----------
@interface DmPadMap : NSObject { @public pad_map map; } @end
@implementation DmPadMap @end

static pad_map g_default;                                  // the map of a controller type without its own
static NSMutableDictionary<NSString *, DmPadMap *> *g_types;   // type → its own map
static BOOL g_swap_sticks, g_game_only;
static float g_deadzone;                                   // 0 to 0.5 of full deflection

static NSString *pad_type(GCController *c) { return c.productCategory ?: @""; }
static const pad_map *map_for(NSString *type) { DmPadMap *m = type.length ? g_types[type] : nil; return m ? &m->map : &g_default; }
static pad_map *map_edit(NSString *type) {   // the type's own map, made from the default the first time ("" is the default map)
    if (!type.length) return &g_default;
    DmPadMap *m = g_types[type];
    if (!m) { m = [DmPadMap new]; m->map = g_default; g_types[type] = m; }
    return &m->map;
}
static void settings_reset(void) { g_default = PAD_MAP_POSITION; g_types = [NSMutableDictionary new]; g_swap_sticks = NO; g_deadzone = 0; }

// ---------- Reading a controller ----------
static GCControllerButtonInput *pad_elem(GCExtendedGamepad *g, int e) {   // nil for an element the pad lacks (stick presses, Options): never pressed
    switch (e) {
        case PE_A: return g.buttonA;            case PE_B: return g.buttonB;             case PE_X: return g.buttonX;              case PE_Y: return g.buttonY;
        case PE_LB: return g.leftShoulder;      case PE_RB: return g.rightShoulder;      case PE_LT: return g.leftTrigger;         case PE_RT: return g.rightTrigger;
        case PE_MENU: return g.buttonMenu;      case PE_OPTIONS: return g.buttonOptions; case PE_LSTICK: return g.leftThumbstickButton; case PE_RSTICK: return g.rightThumbstickButton;
        case PE_UP: return g.dpad.up;           case PE_DOWN: return g.dpad.down;        case PE_LEFT: return g.dpad.left;         case PE_RIGHT: return g.dpad.right;
    }
    return nil;
}
static uint32_t pad_held(GCExtendedGamepad *g) { uint32_t m = 0; for (int e = 0; e < PE_N; e++) if (pad_elem(g, e).isPressed) m |= 1u << e; return m; }
uint64_t controls_buttons(GCExtendedGamepad *g) { return pad_map_press(map_for(pad_type(g.controller)), pad_held(g)); }
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
static NSString *elem_name(GCController *c, int e) {   // what the controller calls the element ("B", "Button X", "L1"), the generic name when it says nothing
    NSString *n = c.extendedGamepad ? pad_elem(c.extendedGamepad, e).localizedName : nil;
    return n.length ? n : @(pad_elem_label[e]);
}
static uint64_t printed_letter(GCControllerButtonInput *b) {   // the Switch face button whose letter is printed on b ("A", "A Button", "Button A"), 0 for none
    NSString *n = [[b.localizedName stringByReplacingOccurrencesOfString:@"button" withString:@"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, b.localizedName.length)]
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    for (int i = 0; i < 4; i++) if ([n caseInsensitiveCompare:@(pad_buttons[i].key)] == NSOrderedSame) return pad_buttons[i].bit;
    return 0;
}
// Each face button presses the Switch button printed on it. When GameController names no letters, a Nintendo controller is laid out as the Switch and any other as Xbox letters
static pad_map map_by_labels(GCController *c) {
    pad_map m = PAD_MAP_POSITION; int found = 0;
    for (int e = PE_A; e <= PE_Y; e++) if ((m.to[e] = c.extendedGamepad ? printed_letter(pad_elem(c.extendedGamepad, e)) : 0)) found++;
    if (found == 4) return m;
    NSString *t = [pad_type(c) stringByAppendingFormat:@" %@", c.vendorName ?: @""];
    BOOL nintendo = [t containsString:@"Switch"] || [t containsString:@"Pro Controller"] || [t containsString:@"Joy-Con"];
    return nintendo ? PAD_MAP_POSITION : PAD_MAP_LETTERS;
}
static NSString *button_label(uint64_t bit) { const pad_button *b = pad_button_of(bit); return b ? @(b->label) : @"nothing"; }

// ---------- controls.plist ----------
// { version 1, defaultMap {element key: button key}, typeMaps {type: {…}}, swapSticks, deadzone, players [8 controller names] }; unknown keys and values are skipped
static NSString *settings_path(BOOL game_only) {
    const char *root = getenv("DM_ROOT");   // the launcher's folder for this game: <nxnative>/<title ID>
    NSString *game = root && *root ? @(root) : [NSHomeDirectory() stringByAppendingFormat:@"/Library/Application Support/nxnative/%016llX", (unsigned long long)dm_profile()->program_id];
    return game_only ? [game stringByAppendingPathComponent:@"controls.plist"] : [game.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"controls.plist"];
}
static NSDictionary *map_to_plist(const pad_map *m) {
    NSMutableDictionary *d = [NSMutableDictionary new];
    for (int e = 0; e < PE_N; e++) { const pad_button *b = pad_button_of(m->to[e]); d[@(pad_elem_key[e])] = b ? @(b->key) : @"None"; }
    return d;
}
static void map_from_plist(id plist, pad_map *m) {
    if (![plist isKindOfClass:NSDictionary.class]) return;
    [(NSDictionary *)plist enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        int e = [k isKindOfClass:NSString.class] ? pad_elem_parse([k UTF8String]) : -1; uint64_t bit;
        if (e >= 0 && [v isKindOfClass:NSString.class] && pad_button_parse([v UTF8String], &bit)) m->to[e] = bit;
    }];
}
void controls_load(char players[DM_PLAYERS][64]) {
    settings_reset(); memset(players, 0, DM_PLAYERS * sizeof players[0]);
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:settings_path(YES)];
    g_game_only = d != nil;
    if (!d) d = [NSDictionary dictionaryWithContentsOfFile:settings_path(NO)];
    if (![d isKindOfClass:NSDictionary.class] || [d[@"version"] integerValue] != 1) { LOG("front end: controller settings: defaults"); return; }
    map_from_plist(d[@"defaultMap"], &g_default);
    NSDictionary *types = d[@"typeMaps"];
    if ([types isKindOfClass:NSDictionary.class]) for (id t in types) if ([t isKindOfClass:NSString.class]) map_from_plist(types[t], map_edit(t));
    g_swap_sticks = [d[@"swapSticks"] boolValue];
    g_deadzone = fminf(0.5f, fmaxf(0.f, [d[@"deadzone"] floatValue]));
    NSArray *names = d[@"players"];
    for (NSUInteger p = 0; [names isKindOfClass:NSArray.class] && p < DM_PLAYERS && p < names.count; p++)
        if ([names[p] isKindOfClass:NSString.class]) snprintf(players[p], sizeof players[p], "%s", [names[p] UTF8String]);
    LOG("front end: controller settings from %s", g_game_only ? "this game's controls.plist" : "the shared controls.plist");
}
static BOOL controls_save(void) {
    NSMutableDictionary *types = [NSMutableDictionary new];
    [g_types enumerateKeysAndObjectsUsingBlock:^(NSString *t, DmPadMap *m, BOOL *stop) { types[t] = map_to_plist(&m->map); }];
    NSMutableArray *names = [NSMutableArray new];
    for (int p = 0; p < DM_PLAYERS; p++) [names addObject:@(pads_player_name(p))];
    NSDictionary *d = @{ @"version": @1, @"defaultMap": map_to_plist(&g_default), @"typeMaps": types, @"swapSticks": @(g_swap_sticks), @"deadzone": @(g_deadzone), @"players": names };
    NSString *path = settings_path(g_game_only);
    NSError *err = nil;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:d format:NSPropertyListXMLFormat_v1_0 options:0 error:&err];
    if (!data || ![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&err]
        || ![data writeToFile:path options:NSDataWritingAtomic error:&err]) {
        LOG("[RED] front end: controller settings not saved to %s: %s", path.UTF8String, err.localizedDescription.UTF8String);
        return NO;
    }
    if (!g_game_only) [NSFileManager.defaultManager removeItemAtPath:settings_path(YES) error:nil];   // back on the shared settings: this game's own copy would win at the next start
    return YES;
}

// ---------- The window ----------
// Press…: the next button pressed on any controller (only one pressed after the click counts, not one already held) is mapped to a Switch button, or puts its controller on a player
typedef NS_ENUM(NSInteger, DmCapture) { DmCaptureNone, DmCaptureButton, DmCapturePlayer };

@interface DmControlsWindow : NSWindowController <NSWindowDelegate>
@end
@implementation DmControlsWindow {
    NSString *_type;                       // the controller type the buttons show ("" = every other controller)
    NSPopUpButton *_typeMenu;
    NSGridView *_players, *_buttons;
    NSButton *_swap, *_gameOnly, *_save;
    NSSlider *_deadzone; NSTextField *_deadzoneValue, *_status;
    int _shownPlayers; BOOL _dirty;
    DmCapture _capture; uint64_t _captureButton; int _capturePlayer;
    NSMapTable<GCController *, NSNumber *> *_heldAtCapture;
}

static NSTextField *label(NSString *s) { return [NSTextField labelWithString:s]; }
static NSTextField *heading(NSString *s) { NSTextField *t = label(s); t.font = [NSFont boldSystemFontOfSize:NSFont.systemFontSize]; return t; }
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
    _swap = [NSButton checkboxWithTitle:@"Swap left and right sticks" target:self action:@selector(swapChanged:)];
    _deadzone = [NSSlider sliderWithValue:0 minValue:0 maxValue:0.5 target:self action:@selector(deadzoneChanged:)];
    [_deadzone.widthAnchor constraintEqualToConstant:220].active = YES;
    _deadzoneValue = label(@"");
    _gameOnly = [NSButton checkboxWithTitle:[NSString stringWithFormat:@"Save for %s only", dm_profile()->name] target:self action:@selector(gameOnlyChanged:)];
    _status = label(@""); _status.textColor = NSColor.secondaryLabelColor; _status.lineBreakMode = NSLineBreakByTruncatingTail;
    [_status.widthAnchor constraintEqualToConstant:600].active = YES;
    _save = [NSButton buttonWithTitle:@"Save" target:self action:@selector(save:)]; _save.keyEquivalent = @"\r";

    NSStackView *root = [NSStackView stackViewWithViews:@[
        heading(@"Players"), _players, [NSButton buttonWithTitle:@"Add Player" target:self action:@selector(addPlayer:)],
        heading(@"Buttons"), row(@[label(@"Controller"), _typeMenu]),
        row(@[[NSButton buttonWithTitle:@"Match Button Labels" target:self action:@selector(matchLabels:)],
              [NSButton buttonWithTitle:@"Switch Layout (by Position)" target:self action:@selector(switchLayout:)]]),
        _buttons,
        heading(@"Sticks"), _swap, row(@[label(@"Deadzone"), _deadzone, _deadzoneValue]),
        _gameOnly, _status,
        row(@[_save, [NSButton buttonWithTitle:@"Revert" target:self action:@selector(revert:)],
              [NSButton buttonWithTitle:@"Reset to Defaults" target:self action:@selector(resetToDefaults:)]]),
    ]];
    root.orientation = NSUserInterfaceLayoutOrientationVertical; root.alignment = NSLayoutAttributeLeading; root.spacing = 10;
    root.edgeInsets = NSEdgeInsetsMake(16, 20, 16, 20);
    self.window.contentView = root;
}

- (void)show {
    if (!_type.length) for (GCController *c in GCController.controllers) if (c.extendedGamepad && pad_type(c).length) { _type = pad_type(c); break; }   // the first controller's own labels
    _capture = DmCaptureNone;
    [self reload]; [self note:nil];
    if (!self.window.visible) [self.window center];
    [self showWindow:nil];
}

// ---------- Contents ----------
- (GCController *)controllerOfType:(NSString *)t {
    if (t.length) for (GCController *c in GCController.controllers) if (c.extendedGamepad && [pad_type(c) isEqualToString:t]) return c;
    return nil;
}
- (void)reload {
    [self reloadPlayers]; [self reloadButtons];
    _swap.state = g_swap_sticks ? NSControlStateValueOn : NSControlStateValueOff;
    _deadzone.doubleValue = g_deadzone; _deadzoneValue.stringValue = [NSString stringWithFormat:@"%d%%", (int)lroundf(g_deadzone * 100)];
    _gameOnly.state = g_game_only ? NSControlStateValueOn : NSControlStateValueOff;
    _save.enabled = _dirty;
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
    if (pads_merged()) [_players addRowWithViews:@[label(@"Every controller is player 1 (DM_PAD_MERGE=1 in env.txt).")]];
}
- (void)reloadButtons {
    NSMutableOrderedSet<NSString *> *types = [NSMutableOrderedSet new];
    for (GCController *c in GCController.controllers) if (c.extendedGamepad && pad_type(c).length) [types addObject:pad_type(c)];
    [types addObjectsFromArray:g_types.allKeys];
    if (![types containsObject:_type]) _type = @"";
    [_typeMenu removeAllItems];
    [_typeMenu addItemWithTitle:@"Every other controller"]; _typeMenu.lastItem.representedObject = @"";
    for (NSString *t in types) { [_typeMenu addItemWithTitle:t]; _typeMenu.lastItem.representedObject = t; }
    [_typeMenu selectItemAtIndex:[_typeMenu indexOfItemWithRepresentedObject:_type]];

    grid_clear(_buttons);
    GCController *example = [self controllerOfType:_type]; const pad_map *m = map_for(_type);
    int half = (PAD_BUTTONS + 1) / 2;
    for (int r = 0; r < half; r++) {
        NSMutableArray *cells = [NSMutableArray new];
        for (int i = r; i < PAD_BUTTONS; i += half) {   // two columns
            NSMutableArray *by = [NSMutableArray new];
            for (int e = 0; e < PE_N; e++) if (m->to[e] == pad_buttons[i].bit) [by addObject:example ? elem_name(example, e) : @(pad_elem_label[e])];
            NSTextField *mapped = label(by.count ? [by componentsJoinedByString:@", "] : @"(none)");
            mapped.textColor = NSColor.secondaryLabelColor; mapped.lineBreakMode = NSLineBreakByTruncatingTail; mapped.toolTip = mapped.stringValue;
            [mapped.widthAnchor constraintEqualToConstant:150].active = YES;
            NSButton *press = [NSButton buttonWithTitle:_capture == DmCaptureButton && _captureButton == pad_buttons[i].bit ? @"Waiting…" : @"Press…"
                                                 target:self action:@selector(pressForButton:)];
            press.tag = i;
            [cells addObjectsFromArray:@[heading(@(pad_buttons[i].label)), mapped, press]];
        }
        while (cells.count < 6) [cells addObject:NSGridCell.emptyContentView];
        [_buttons addRowWithViews:cells];
    }
}
- (void)note:(NSString *)s {
    _status.stringValue = s ?: _dirty ? @"These changes are playing now. Click Save to keep them." : @"Press a button on a controller to see what it does.";
}
- (void)changed:(NSString *)note {   // a setting changed: it plays at once and waits for Save
    _dirty = YES; pads_reread(); [self reload]; [self note:note];
}

// ---------- Live line and captures (every controller change, controls_seen) ----------
- (void)seen:(GCExtendedGamepad *)g {
    uint32_t held = pad_held(g);
    if (_capture == DmCaptureNone) {
        NSMutableArray *on = [NSMutableArray new];
        const pad_map *m = map_for(pad_type(g.controller));
        for (int e = 0; e < PE_N; e++) if (held >> e & 1) [on addObject:[NSString stringWithFormat:@"%@ → %@", elem_name(g.controller, e), button_label(m->to[e])]];
        if (on.count) [self note:[NSString stringWithFormat:@"%s: %@", pad_name(g.controller), [on componentsJoinedByString:@", "]]];
        return;
    }
    uint32_t before = [_heldAtCapture objectForKey:g.controller].unsignedIntValue, fresh = held & ~before;
    [_heldAtCapture setObject:@(held & before) forKey:g.controller];   // a button let go counts once it is pressed again
    if (!fresh) return;
    int e = __builtin_ctz(fresh);
    DmCapture kind = _capture; _capture = DmCaptureNone;
    if (kind == DmCaptureButton) {
        _type = pad_type(g.controller);   // the map of the controller pressed
        pad_map_assign(map_edit(_type), e, _captureButton);
        [self changed:[NSString stringWithFormat:@"%@ on %s now presses %@. Click Save to keep it.", elem_name(g.controller, e), pad_name(g.controller), button_label(_captureButton)]];
    } else {
        pads_assign(g.controller, _capturePlayer);
        [self changed:[NSString stringWithFormat:@"%s is player %d. Click Save to keep it.", pad_name(g.controller), _capturePlayer + 1]];
    }
}
- (void)startCapture:(DmCapture)kind {
    _capture = kind;
    _heldAtCapture = [NSMapTable weakToStrongObjectsMapTable];
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) [_heldAtCapture setObject:@(pad_held(c.extendedGamepad)) forKey:c];
    [self reload];
    [self note:kind == DmCaptureButton ? [NSString stringWithFormat:@"Press the controller button that should be %@… (Esc cancels)", button_label(_captureButton)]
                                       : [NSString stringWithFormat:@"Press any button on the controller for player %d… (Esc cancels)", _capturePlayer + 1]];
}
- (void)cancelOperation:(id)sender { if (_capture != DmCaptureNone) { _capture = DmCaptureNone; [self reload]; [self note:nil]; } }

// ---------- Actions ----------
- (void)pressForButton:(NSButton *)b { _captureButton = pad_buttons[b.tag].bit; [self startCapture:DmCaptureButton]; }
- (void)pressForPlayer:(NSButton *)b { _capturePlayer = (int)b.tag; [self startCapture:DmCapturePlayer]; }
- (void)addPlayer:(id)sender { if (_shownPlayers < DM_PLAYERS) { _capturePlayer = _shownPlayers++; [self startCapture:DmCapturePlayer]; } }
- (void)removePlayer:(NSButton *)b { pads_unassign((int)b.tag); [self changed:nil]; }
- (void)typeChosen:(NSPopUpButton *)m { _type = m.selectedItem.representedObject ?: @""; [self reloadButtons]; }
- (void)matchLabels:(id)sender {
    GCController *c = [self controllerOfType:_type];
    *map_edit(_type) = c ? map_by_labels(c) : PAD_MAP_LETTERS;
    [self changed:[NSString stringWithFormat:@"%@: each face button presses the letter printed on it. Click Save to keep it.", c ? @(pad_name(c)) : @"Every other controller"]];
}
- (void)switchLayout:(id)sender { *map_edit(_type) = PAD_MAP_POSITION; [self changed:nil]; }
- (void)swapChanged:(NSButton *)b { g_swap_sticks = b.state == NSControlStateValueOn; [self changed:nil]; }
- (void)deadzoneChanged:(NSSlider *)s { g_deadzone = (float)s.doubleValue; [self changed:nil]; }
- (void)gameOnlyChanged:(NSButton *)b { g_game_only = b.state == NSControlStateValueOn; _dirty = YES; [self reload]; [self note:nil]; }
- (void)resetToDefaults:(id)sender { settings_reset(); [self changed:nil]; }
- (void)save:(id)sender {
    if (!controls_save()) { [self note:@"Could not save the settings (see the game's log)."]; return; }
    _dirty = NO; [self reload];
    [self note:g_game_only ? [NSString stringWithFormat:@"Saved for %s only.", dm_profile()->name] : @"Saved for every game."];
}
- (void)revert:(id)sender {   // the saved buttons and sticks again; the players stay where they are
    char unused[DM_PLAYERS][64]; controls_load(unused);
    _dirty = NO; _capture = DmCaptureNone; pads_reread(); [self reload]; [self note:@"Back to the saved settings."];
}
- (BOOL)windowShouldClose:(NSWindow *)w {
    if (!_dirty) return YES;
    NSAlert *a = [NSAlert new];
    a.messageText = @"Save your controller changes?";
    a.informativeText = @"They are playing now. Without saving, the game starts with the saved settings next time.";
    [a addButtonWithTitle:@"Save"]; [a addButtonWithTitle:@"Don't Save"]; [a addButtonWithTitle:@"Cancel"];
    switch ([a runModal]) {
        case NSAlertFirstButtonReturn: [self save:nil]; return !_dirty;
        case NSAlertSecondButtonReturn: [self revert:nil]; return YES;
        default: return NO;
    }
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
