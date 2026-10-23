// pocket-viewer — live video/audio from DJI Osmo Pocket 3 (webcam mode) with gimbal control.
//
//   Arrow keys / WASD   move gimbal by one step      [ ]  step smaller / larger
//   Mouse drag          pan/tilt with the mouse      scroll / + -  zoom
//   Click / ⌥-drag      point at / box something for plugins (e.g. tracker); Esc cancels
//   Space (hold)        push-to-talk for plugins (e.g. ai-agent)
//   c                   center                       m    toggle audio monitoring (output: Audio Output menu)
//   Audio Output menu → Echo Cancellation (experimental): voice-processed capture, see echocancel.h
//   f                   toggle fullscreen            q    quit
//   , .                 roll left / right            r / ⌘R  start / stop recording
//   v                   video scaling: fill (crop) / fit (letterbox) / stretch
//   ⌘1..⌘9              switch resolution (also in the Resolution / Frame Rate menus)
//
// Usage: pocket-viewer [-d device] [-s WxH] [-r fps] [-a audio] [-o dir] [-c codec] [-e] [-p cmd]... [-t secs] [-l]
//   -d dev   stackchan or stackchan:/dev/cu.… — use an M5Stack StackChan running
//            stackchan/firmware/stackchan-cam, plugged in over USB, as the camera and
//            gimbal instead of the Pocket 3. Audio defaults to the Mac's input.
//   -s WxH   initial resolution, e.g. 3840x2160 or 1080x1920 (portrait); default 1920x1080
//   -r fps   initial frame rate; default the highest the resolution supports
//   -a name  audio input to use (substring of its name, e.g. AG06); default the Pocket 3 mic.
//            With StackChan, "none" runs video only without asking for microphone access.
//            Also switchable at runtime from the Audio Input menu.
//   -o dir   where recordings are saved; default the folder chosen in the Record menu (~/Movies)
//   -c codec recording video codec: hevc, h264 or prores; default the Record menu choice (hevc)
//   -e       start with echo cancellation on (experimental)
//   -t secs  record immediately for secs seconds, then quit
//   -p cmd   launch a plugin (shell command); repeatable. See plugins/PROTOCOL.md
//   -l       list available resolutions, frame rates and audio inputs, then exit

#import <AVFoundation/AVFoundation.h>
#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>

#include "gimbal.h"
#import "echocancel.h"
#import "moviewriter.h"
#import "plugins.h"
#import "stackchan.h"

static NSString *const kDeviceName = @"OsmoPocket3";

static double clampd(double x, double lo, double hi) { return x < lo ? lo : x > hi ? hi : x; }

// The layer showing the video: the capture session's preview for the Pocket 3,
// a sample buffer display layer for StackChan. Both scale by videoGravity.
@protocol VideoLayer <NSObject>
@property(copy) AVLayerVideoGravity videoGravity;
@end
@interface AVCaptureVideoPreviewLayer (VideoLayer) <VideoLayer>
@end
@implementation AVCaptureVideoPreviewLayer (VideoLayer)
@end
@interface AVSampleBufferDisplayLayer (VideoLayer) <VideoLayer>
@end
@implementation AVSampleBufferDisplayLayer (VideoLayer)
@end

// Draws what plugins send (boxes, lines, labels, subtitles) over the video.
// Coordinates are normalized to the video frame, origin top-left, and follow
// the preview's scaling mode. Each plugin layer is replaced wholesale by its
// next draw and can expire on its own (ttl).
@interface OverlayView : NSView
@property(nonatomic, weak) CALayer<VideoLayer> *preview;
@property(nonatomic) CGSize videoSize;
@property(nonatomic) NSRect selection;  // ⌥-drag rubber band, normalized; empty when none
- (NSPoint)normalize:(NSPoint)point;    // view point -> normalized video coordinates
- (void)setItems:(NSArray *)items forKey:(NSString *)key ttl:(double)ttl;
- (void)removeKeysWithPrefix:(NSString *)prefix;
- (void)keepClients:(NSSet<NSNumber *> *)clientIDs;  // drops layers of disconnected plugins
@end

static NSColor *colorFromHex(id value, NSColor *fallback) {
  if (![value isKindOfClass:NSString.class] || ![value hasPrefix:@"#"]) return fallback;
  unsigned v = 0;
  NSString *hex = [value substringFromIndex:1];
  if (![[NSScanner scannerWithString:hex] scanHexInt:&v]) return fallback;
  if (hex.length == 6) v = (v << 8) | 0xff;
  else if (hex.length != 8) return fallback;
  return [NSColor colorWithSRGBRed:(v >> 24 & 0xff) / 255.0
                             green:(v >> 16 & 0xff) / 255.0
                              blue:(v >> 8 & 0xff) / 255.0
                             alpha:(v & 0xff) / 255.0];
}

static double num(NSDictionary *d, NSString *key, double fallback) {
  id v = d[key];
  return [v isKindOfClass:NSNumber.class] ? [v doubleValue] : fallback;
}

@implementation OverlayView {
  NSMutableDictionary<NSString *, NSDictionary *> *_layers;  // key -> {items, expires}
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _layers = [NSMutableDictionary dictionary];
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(expire) userInfo:nil repeats:YES];
  }
  return self;
}

- (NSView *)hitTest:(NSPoint)point {
  return nil;  // never steal clicks, drags or the right-click menu from the video view
}

- (void)setItems:(NSArray *)items forKey:(NSString *)key ttl:(double)ttl {
  _layers[key] = @{@"items" : items, @"expires" : @(ttl > 0 ? CACurrentMediaTime() + ttl : INFINITY)};
  self.needsDisplay = YES;
}

- (void)removeKeysWithPrefix:(NSString *)prefix {
  for (NSString *key in _layers.allKeys)
    if ([key hasPrefix:prefix]) [_layers removeObjectForKey:key];
  self.needsDisplay = YES;
}

- (void)keepClients:(NSSet<NSNumber *> *)clientIDs {
  for (NSString *key in _layers.allKeys)
    if (![clientIDs containsObject:@(key.intValue)]) [_layers removeObjectForKey:key];
  self.needsDisplay = YES;
}

- (void)expire {
  double now = CACurrentMediaTime();
  for (NSString *key in _layers.allKeys)
    if ([_layers[key][@"expires"] doubleValue] < now) {
      [_layers removeObjectForKey:key];
      self.needsDisplay = YES;
    }
}

- (void)setSelection:(NSRect)selection {
  _selection = selection;
  self.needsDisplay = YES;
}

- (NSPoint)normalize:(NSPoint)p {
  NSRect v = self.videoRect;
  return NSMakePoint((p.x - NSMinX(v)) / v.size.width, (NSMaxY(v) - p.y) / v.size.height);
}

// Where the video lands in this view under the preview's current scaling.
- (NSRect)videoRect {
  NSRect b = self.bounds;
  CGSize v = self.videoSize;
  NSString *gravity = self.preview.videoGravity;
  if (v.width <= 0 || v.height <= 0 || [gravity isEqual:AVLayerVideoGravityResize]) return b;
  double sx = b.size.width / v.width, sy = b.size.height / v.height;
  double scale = [gravity isEqual:AVLayerVideoGravityResizeAspectFill] ? MAX(sx, sy) : MIN(sx, sy);
  double w = v.width * scale, h = v.height * scale;
  return NSMakeRect(NSMidX(b) - w / 2, NSMidY(b) - h / 2, w, h);
}

static void drawLabel(NSString *text, NSPoint origin, double size, NSColor *color, NSColor *background) {
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:size weight:NSFontWeightSemibold],
    NSForegroundColorAttributeName : color
  };
  NSSize sz = [text sizeWithAttributes:attrs];
  NSRect box = NSMakeRect(origin.x, origin.y, sz.width + 8, sz.height + 4);
  if (background) {
    [background setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:3 yRadius:3] fill];
  }
  [text drawAtPoint:NSMakePoint(origin.x + 4, origin.y + 2) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirty {
  NSRect v = self.videoRect;
  NSRect visible = NSIntersectionRect(v, self.bounds);
  // Normalized (top-left origin) -> view (bottom-left origin).
  NSPoint (^pt)(double, double) = ^NSPoint(double x, double y) {
    return NSMakePoint(NSMinX(v) + x * v.size.width, NSMaxY(v) - y * v.size.height);
  };
  NSMutableArray<NSDictionary *> *subtitles = [NSMutableArray array];

  for (NSString *key in [_layers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    for (NSDictionary *item in _layers[key][@"items"]) {
      if (![item isKindOfClass:NSDictionary.class]) continue;
      NSString *shape = item[@"shape"];
      NSColor *color = colorFromHex(item[@"color"], NSColor.systemGreenColor);
      double width = num(item, @"width", 2);
      if ([shape isEqual:@"rect"]) {
        NSPoint tl = pt(num(item, @"x", 0), num(item, @"y", 0));
        NSPoint br = pt(num(item, @"x", 0) + num(item, @"w", 0), num(item, @"y", 0) + num(item, @"h", 0));
        NSRect r = NSMakeRect(tl.x, br.y, br.x - tl.x, tl.y - br.y);
        NSColor *fill = colorFromHex(item[@"fill"], nil);
        if (fill) {
          [fill setFill];
          NSRectFillUsingOperation(r, NSCompositingOperationSourceOver);
        }
        NSBezierPath *path = [NSBezierPath bezierPathWithRect:r];
        path.lineWidth = width;
        [color setStroke];
        [path stroke];
        if ([item[@"label"] isKindOfClass:NSString.class])
          drawLabel(item[@"label"], NSMakePoint(r.origin.x - width / 2, NSMaxY(r) + width / 2),
                    num(item, @"size", 13), NSColor.blackColor, color);
      } else if ([shape isEqual:@"line"]) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        [path moveToPoint:pt(num(item, @"x1", 0), num(item, @"y1", 0))];
        [path lineToPoint:pt(num(item, @"x2", 0), num(item, @"y2", 0))];
        path.lineWidth = width;
        [color setStroke];
        [path stroke];
      } else if ([shape isEqual:@"text"] && [item[@"text"] isKindOfClass:NSString.class]) {
        double size = num(item, @"size", 15);
        NSPoint p = pt(num(item, @"x", 0), num(item, @"y", 0));
        drawLabel(item[@"text"], NSMakePoint(p.x, p.y - size - 6), size, colorFromHex(item[@"color"], NSColor.whiteColor),
                  colorFromHex(item[@"background"], [NSColor colorWithWhite:0 alpha:0.55]));
      } else if ([shape isEqual:@"subtitle"] && [item[@"text"] isKindOfClass:NSString.class]) {
        [subtitles addObject:item];
      }
    }
  }

  if (!NSIsEmptyRect(self.selection)) {
    NSRect s = self.selection;
    NSPoint tl = pt(NSMinX(s), NSMinY(s)), br = pt(NSMaxX(s), NSMaxY(s));
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSMakeRect(tl.x, br.y, br.x - tl.x, tl.y - br.y)];
    CGFloat dash[] = {6, 4};
    [path setLineDash:dash count:2 phase:0];
    path.lineWidth = 2;
    [NSColor.whiteColor setStroke];
    [path stroke];
  }

  // Subtitles stack upward from the bottom of the visible video, centered and wrapped.
  double y = NSMinY(visible) + 24;
  for (NSDictionary *item in subtitles.reverseObjectEnumerator) {
    double size = num(item, @"size", 24);
    NSMutableParagraphStyle *para = [NSMutableParagraphStyle new];
    para.alignment = NSTextAlignmentCenter;
    NSAttributedString *text = [[NSAttributedString alloc]
        initWithString:item[@"text"]
            attributes:@{
              NSFontAttributeName : [NSFont systemFontOfSize:size weight:NSFontWeightMedium],
              NSForegroundColorAttributeName : colorFromHex(item[@"color"], NSColor.whiteColor),
              NSParagraphStyleAttributeName : para
            }];
    double maxWidth = visible.size.width * 0.9;
    NSRect bounds = [text boundingRectWithSize:NSMakeSize(maxWidth, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin];
    NSRect box = NSMakeRect(NSMidX(visible) - bounds.size.width / 2 - 12, y, bounds.size.width + 24,
                            bounds.size.height + 12);
    [colorFromHex(item[@"background"], [NSColor colorWithWhite:0 alpha:0.6]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:box xRadius:6 yRadius:6] fill];
    [text drawWithRect:NSInsetRect(box, 12, 6) options:NSStringDrawingUsesLineFragmentOrigin];
    y = NSMaxY(box) + 8;
  }
}

@end

@interface ControlView : NSView
@property(nonatomic) AVCaptureSession *session;
@property(nonatomic) AVCaptureAudioPreviewOutput *monitor;
@property(nonatomic) AVCaptureConnection *audioConnection;
@property(nonatomic, weak) EchoCanceller *echoCanceller;  // when set, the HUD meters it instead
@property(nonatomic) BOOL monitoring;
@property(nonatomic) NSTextField *hud;
@property(nonatomic, copy) NSString *formatInfo;
@property(nonatomic) CALayer<VideoLayer> *preview;
@property(nonatomic) NSDate *recordingSince;  // nil when not recording
@property(nonatomic, copy) NSMenu * (^menuProvider)(void);  // right-click menu
@property(nonatomic) OverlayView *overlay;
// Clicks, ⌥-drag boxes and Esc on the video, for plugins (see "input" in PROTOCOL.md).
@property(nonatomic, copy) void (^inputHandler)(NSDictionary *event);
- (void)fillGravityMenu:(NSMenu *)menu;
- (void)handlePluginCommand:(NSDictionary *)msg;  // gimbal / zoom / roll / center
// Plugin status shown on a HUD line of its own. key is "clientID/name"; empty
// text removes it, ttl > 0 expires it.
- (void)setHudText:(NSString *)text color:(NSColor *)color forKey:(NSString *)key ttl:(double)ttl;
- (void)keepHudClients:(NSSet<NSNumber *> *)clientIDs;
- (NSDictionary *)gimbalState;
@end

@implementation ControlView {
  dispatch_queue_t _gimbalQueue;
  BOOL _hasGimbal;
  gimbal_range _range;
  double _pan, _tilt, _roll, _step;
  int _zoom;                     // last value sent to the camera
  double _zoomTarget, _zoomPos;  // smooth zoom: _zoomPos eases toward _zoomTarget
  NSTimer *_zoomTimer;
  BOOL _sendPending, _zoomSendPending;
  double _actualPan, _actualTilt;  // read back from the camera every 0.2 s
  double _lastCommand;             // CACurrentMediaTime of the last pan/tilt command
  NSPoint _mouseDown;              // view coordinates
  BOOL _dragged, _selecting;       // this press moved / is an ⌥-drag selection
  NSMutableDictionary<NSString *, NSDictionary *> *_pluginHud;  // key -> {text, color, expires}
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _gimbalQueue = dispatch_queue_create("gimbal", DISPATCH_QUEUE_SERIAL);
    _step = 5;
    _pluginHud = [NSMutableDictionary dictionary];
    _hasGimbal = gimbal_open(&_range) == 0 && gimbal_get(&_pan, &_tilt) == 0 &&
                 gimbal_get_zoom(&_zoom) == 0 && gimbal_get_roll(&_roll) == 0;
    _zoomTarget = _zoomPos = _zoom;
    _actualPan = _pan;
    _actualTilt = _tilt;
    if (_hasGimbal)
      [NSTimer scheduledTimerWithTimeInterval:0.2 target:self selector:@selector(pollActual) userInfo:nil repeats:YES];
    if (!_hasGimbal) NSLog(@"gimbal control unavailable");

    self.wantsLayer = YES;
    self.layer.backgroundColor = NSColor.blackColor.CGColor;

    _overlay = [[OverlayView alloc] initWithFrame:self.bounds];
    _overlay.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self addSubview:_overlay];  // below the HUD, above the video layer

    _hud = [NSTextField labelWithString:@""];
    _hud.font = [NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightMedium];
    _hud.textColor = NSColor.whiteColor;
    _hud.drawsBackground = YES;
    _hud.backgroundColor = [NSColor colorWithWhite:0 alpha:0.5];
    _hud.frame = NSMakeRect(10, 10, 640, 20);
    _hud.autoresizingMask = NSViewMaxYMargin;
    [self addSubview:_hud];

    [NSTimer scheduledTimerWithTimeInterval:0.1
                                     target:self
                                   selector:@selector(updateHud)
                                   userInfo:nil
                                    repeats:YES];
  }
  return self;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)updateHud {
  float db = -160;
  if (self.echoCanceller)
    db = self.echoCanceller.levelDB;
  else
    for (AVCaptureAudioChannel *ch in self.audioConnection.audioChannels) db = MAX(db, ch.averagePowerLevel);
  int bars = (int)clampd((db + 60) / 3, 0, 20);
  NSString *meter = [@"" stringByPaddingToLength:bars withString:@"|" startingAtIndex:0];
  NSString *gimbal = _hasGimbal ? [NSString stringWithFormat:@"pan %6.1f°  tilt %5.1f°  roll %3.0f°  "
                                                             @"zoom %3d  step %4.1f°",
                                                             _pan, _tilt, _roll, _zoom, _step]
                                : @"gimbal: n/a";
  NSString *rec = @"";
  if (self.recordingSince) {
    int t = (int)-self.recordingSince.timeIntervalSinceNow;
    rec = [NSString stringWithFormat:@"🔴 REC %02d:%02d:%02d   ", t / 3600, t / 60 % 60, t % 60];
  }
  NSString *line =
      [NSString stringWithFormat:@" %@%@ %@   %@   audio%@ %@ %-20s %5.0f dB ", rec, self.formatInfo,
                                 self.gravityName, gimbal, self.echoCanceller ? @" [AEC]" : @"",
                                 self.monitoring ? @"🔊" : @"🔇",
                                 meter.UTF8String, db];
  NSDictionary *attrs = @{NSFontAttributeName : self.hud.font, NSForegroundColorAttributeName : NSColor.whiteColor};
  NSMutableAttributedString *text = [NSMutableAttributedString new];
  // Plugin segments go on a line above the built-in one, in key order (plugin, then name).
  double now = CACurrentMediaTime();
  NSArray *keys = [_pluginHud.allKeys sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
  for (NSString *key in keys) {
    NSDictionary *seg = _pluginHud[key];
    if ([seg[@"expires"] doubleValue] < now) {
      [_pluginHud removeObjectForKey:key];
      continue;
    }
    NSMutableDictionary *a = [attrs mutableCopy];
    a[NSForegroundColorAttributeName] = seg[@"color"];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:attrs]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:seg[@"text"] attributes:a]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"  " attributes:attrs]];
  }
  if (text.length) [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:attrs]];
  [text appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:attrs]];
  self.hud.attributedStringValue = text;
  [self.hud sizeToFit];
}

- (void)setHudText:(NSString *)text color:(NSColor *)color forKey:(NSString *)key ttl:(double)ttl {
  if (!text.length) {
    [_pluginHud removeObjectForKey:key];
  } else {
    if (text.length > 200) text = [text substringToIndex:200];
    text = [[text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
    _pluginHud[key] = @{@"text" : text, @"color" : color, @"expires" : @(ttl > 0 ? CACurrentMediaTime() + ttl : INFINITY)};
  }
  [self updateHud];
}

- (void)keepHudClients:(NSSet<NSNumber *> *)clientIDs {
  for (NSString *key in _pluginHud.allKeys)
    if (![clientIDs containsObject:@(key.intValue)]) [_pluginHud removeObjectForKey:key];
}

// Coalesces rapid updates (key repeat, mouse drag) so the USB pipe only ever
// carries the latest target instead of a backlog.
- (void)sendPosition {
  if (!_hasGimbal) return;
  _lastCommand = CACurrentMediaTime();
  _pan = clampd(_pan, _range.pan_min, _range.pan_max);
  _tilt = clampd(_tilt, _range.tilt_min, _range.tilt_max);
  if (_sendPending) return;
  _sendPending = YES;
  dispatch_async(_gimbalQueue, ^{
    __block double pan, tilt;
    dispatch_sync(dispatch_get_main_queue(), ^{
      pan = self->_pan;
      tilt = self->_tilt;
      self->_sendPending = NO;
    });
    gimbal_set(pan, tilt);
  });
}

// Zoom input only moves the target; zoomTick glides there in single steps so
// the camera never jumps several zoom levels at once.
- (void)setZoom:(double)target {
  if (!_hasGimbal) return;
  _zoomTarget = clampd(target, _range.zoom_min, _range.zoom_max);
  if (!_zoomTimer)
    _zoomTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 60
                                                  target:self
                                                selector:@selector(zoomTick)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)zoomTick {
  double diff = _zoomTarget - _zoomPos;
  if (fabs(diff) < 0.5) {
    _zoomPos = _zoomTarget;
    [_zoomTimer invalidate];
    _zoomTimer = nil;
  } else {
    // Ease out: cover a fraction of the remaining distance each frame, but at
    // least half a level so the tail doesn't crawl.
    double step = diff * 0.12;
    _zoomPos += fabs(step) < 0.5 ? copysign(0.5, diff) : step;
  }
  int z = (int)lround(_zoomPos);
  if (z == _zoom) return;
  _zoom = z;
  // Coalesce like sendPosition: the USB queue only ever sends the latest level.
  if (_zoomSendPending) return;
  _zoomSendPending = YES;
  dispatch_async(_gimbalQueue, ^{
    __block int latest;
    dispatch_sync(dispatch_get_main_queue(), ^{
      latest = self->_zoom;
      self->_zoomSendPending = NO;
    });
    gimbal_set_zoom(latest);
  });
}

- (void)setRoll:(double)roll {
  if (!_hasGimbal) return;
  _roll = clampd(roll, -30, 30);
  double v = _roll;
  dispatch_async(_gimbalQueue, ^{
    gimbal_set_roll(v);
  });
}

- (void)cycleGravity {
  NSArray<AVLayerVideoGravity> *modes = @[
    AVLayerVideoGravityResizeAspectFill, AVLayerVideoGravityResizeAspect,
    AVLayerVideoGravityResize
  ];
  NSUInteger i = [modes indexOfObject:self.preview.videoGravity];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.preview.videoGravity = modes[(i + 1) % modes.count];
  [CATransaction commit];
}

- (void)fillGravityMenu:(NSMenu *)menu {
  NSArray *modes = @[
    @[ AVLayerVideoGravityResizeAspectFill, @"Fill (crop)" ],
    @[ AVLayerVideoGravityResizeAspect, @"Fit (letterbox)" ], @[ AVLayerVideoGravityResize, @"Stretch" ]
  ];
  for (NSArray *m in modes) {
    NSMenuItem *item = [menu addItemWithTitle:m[1] action:@selector(chooseGravity:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = m[0];
  }
}

- (void)chooseGravity:(NSMenuItem *)item {
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.preview.videoGravity = item.representedObject;
  [CATransaction commit];
}

// Reads where the gimbal really is. Once nothing has been commanded for a
// while, a mismatch means something else moved it (pocketctl, the handle's own
// follow behavior), so adopt the real position as the base for relative moves.
- (void)pollActual {
  dispatch_async(_gimbalQueue, ^{
    double pan, tilt;
    if (gimbal_get(&pan, &tilt)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_actualPan = pan;
      self->_actualTilt = tilt;
      if (CACurrentMediaTime() - self->_lastCommand > 2 &&
          (fabs(pan - self->_pan) > 1 || fabs(tilt - self->_tilt) > 1)) {
        self->_pan = pan;
        self->_tilt = tilt;
      }
    });
  });
}

// Plugin commands. Absolute values win over relative ones in the same message.
- (void)handlePluginCommand:(NSDictionary *)m {
  NSString *type = m[@"type"];
  if ([type isEqual:@"gimbal"]) {
    _pan = num(m, @"pan", _pan + num(m, @"dpan", 0));
    _tilt = num(m, @"tilt", _tilt + num(m, @"dtilt", 0));
    [self sendPosition];
  } else if ([type isEqual:@"zoom"]) {
    [self setZoom:num(m, @"zoom", _zoomTarget + num(m, @"dzoom", 0))];
  } else if ([type isEqual:@"roll"]) {
    [self setRoll:num(m, @"roll", _roll + num(m, @"droll", 0))];
  } else if ([type isEqual:@"center"]) {
    [self centerGimbal:nil];
  }
}

// pan/tilt are the commanded target; actualPan/actualTilt the last readback.
- (NSDictionary *)gimbalState {
  if (!_hasGimbal) return @{};
  return @{
    @"pan" : @(_pan),
    @"tilt" : @(_tilt),
    @"actualPan" : @(_actualPan),  // where the camera is now; lags pan/tilt while moving
    @"actualTilt" : @(_actualTilt),
    @"roll" : @(_roll),
    @"zoom" : @(_zoomTarget),
    @"panRange" : @[ @(_range.pan_min), @(_range.pan_max) ],
    @"tiltRange" : @[ @(_range.tilt_min), @(_range.tilt_max) ],
    @"zoomRange" : @[ @(_range.zoom_min), @(_range.zoom_max) ],
  };
}

- (void)centerGimbal:(id)sender {
  _pan = 0;
  _tilt = 0;
  [self sendPosition];
  [self setRoll:0];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(chooseGravity:))
    item.state = [item.representedObject isEqual:self.preview.videoGravity] ? NSControlStateValueOn
                                                                             : NSControlStateValueOff;
  if (item.action == @selector(centerGimbal:)) return _hasGimbal;
  return YES;
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
  return self.menuProvider ? self.menuProvider() : nil;
}

- (NSString *)gravityName {
  NSString *g = self.preview.videoGravity;
  return [g isEqual:AVLayerVideoGravityResizeAspectFill] ? @"fill"
         : [g isEqual:AVLayerVideoGravityResizeAspect]   ? @"fit"
                                                          : @"stretch";
}

- (void)sendInput:(NSDictionary *)event {
  if (self.inputHandler) self.inputHandler(event);
}

- (void)keyDown:(NSEvent *)event {
  switch (event.keyCode) {
    case 53: [self sendInput:@{@"event" : @"cancel"}]; return;  // Esc
    case 49:                                                     // Space: push-to-talk
      if (!event.isARepeat) [self sendInput:@{@"event" : @"key", @"key" : @"space", @"state" : @"down"}];
      return;
    case 126: _tilt += _step; [self sendPosition]; return;  // up
    case 125: _tilt -= _step; [self sendPosition]; return;  // down
    case 123: _pan -= _step; [self sendPosition]; return;   // left
    case 124: _pan += _step; [self sendPosition]; return;   // right
  }
  double zoomStep = (_range.zoom_max - _range.zoom_min) / 10.0;
  switch ([event.charactersIgnoringModifiers.lowercaseString characterAtIndex:0]) {
    case 'w': _tilt += _step; [self sendPosition]; break;
    case 's': _tilt -= _step; [self sendPosition]; break;
    case 'a': _pan -= _step; [self sendPosition]; break;
    case 'd': _pan += _step; [self sendPosition]; break;
    case 'c': [self centerGimbal:nil]; break;
    case ',': [self setRoll:_roll - 2]; break;
    case '.': [self setRoll:_roll + 2]; break;
    case 'r': [NSApp sendAction:@selector(toggleRecording:) to:nil from:self]; break;
    case ']': _step = clampd(_step * 2, 0.5, 45); break;
    case '[': _step = clampd(_step / 2, 0.5, 45); break;
    case '+': case '=': [self setZoom:_zoomTarget + zoomStep]; break;
    case '-': [self setZoom:_zoomTarget - zoomStep]; break;
    case 'm': [NSApp sendAction:@selector(toggleMonitor:) to:nil from:self]; break;
    case 'f': [self.window toggleFullScreen:nil]; break;
    case 'v': [self cycleGravity]; break;
    case 'q': [NSApp terminate:nil]; break;
  }
}

- (void)keyUp:(NSEvent *)event {
  if (event.keyCode == 49) [self sendInput:@{@"event" : @"key", @"key" : @"space", @"state" : @"up"}];
}

- (void)mouseDown:(NSEvent *)event {
  _mouseDown = [self convertPoint:event.locationInWindow fromView:nil];
  _dragged = NO;
  _selecting = (event.modifierFlags & NSEventModifierFlagOption) != 0;
}

- (NSRect)selectionTo:(NSEvent *)event {
  NSPoint a = [self.overlay normalize:_mouseDown];
  NSPoint b = [self.overlay normalize:[self convertPoint:event.locationInWindow fromView:nil]];
  NSRect r = NSMakeRect(MIN(a.x, b.x), MIN(a.y, b.y), fabs(a.x - b.x), fabs(a.y - b.y));
  return NSIntersectionRect(r, NSMakeRect(0, 0, 1, 1));
}

- (void)mouseDragged:(NSEvent *)event {
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  if (hypot(p.x - _mouseDown.x, p.y - _mouseDown.y) > 3) _dragged = YES;
  if (_selecting) {
    self.overlay.selection = [self selectionTo:event];
    return;
  }
  // Drag the scene: moving the mouse right pans right, up tilts up.
  _pan += event.deltaX * 0.15;
  _tilt -= event.deltaY * 0.15;
  [self sendPosition];
}

// A click (no drag) or a finished ⌥-drag box goes to plugins, in normalized
// video coordinates, origin top-left.
- (void)mouseUp:(NSEvent *)event {
  if (_selecting && _dragged) {
    NSRect r = [self selectionTo:event];
    self.overlay.selection = NSZeroRect;
    if (r.size.width > 0.005 && r.size.height > 0.005)
      [self sendInput:@{@"event" : @"select", @"x" : @(r.origin.x), @"y" : @(r.origin.y),
                        @"w" : @(r.size.width), @"h" : @(r.size.height)}];
    return;
  }
  if (_dragged) return;
  NSPoint n = [self.overlay normalize:_mouseDown];
  if (n.x < 0 || n.x > 1 || n.y < 0 || n.y > 1) return;  // on the letterbox
  [self sendInput:@{@"event" : @"click", @"x" : @(n.x), @"y" : @(n.y)}];
}

- (void)scrollWheel:(NSEvent *)event {
  [self setZoom:_zoomTarget + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.5 : 5)];
}
@end

@interface AppDelegate
    : NSObject <NSApplicationDelegate, NSMenuDelegate, AVCaptureFileOutputRecordingDelegate,
                AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate,
                PluginServerDelegate>
@property(nonatomic) PluginServer *plugins;
@property(nonatomic) AVCaptureAudioDataOutput *audioData;  // feeds plugins in normal (non echo-cancel) mode
@property(nonatomic) AVCaptureDevice *selectedAudio;  // what the user picked; may be routed via echo cancel
@property(nonatomic, copy) NSString *monitorSetting, *lastMonitorOn;  // kDefaultsMonitor values
@property(nonatomic) BOOL echoCancel;
@property(nonatomic) EchoCanceller *ec;
@property(nonatomic, copy) NSString *ecInputUID, *ecOutputUID;
@property(nonatomic) AVCaptureVideoDataOutput *videoData;  // feeds plugins, and the writer in echo-cancel mode
@property(atomic) MovieWriter *writer;                     // read on the video and audio threads
@property(nonatomic) BOOL finishingWriter;
@property(nonatomic, readonly) BOOL isRecording;
@property(nonatomic) AVCaptureAudioPreviewOutput *monitor;
@property(nonatomic) AVCaptureDeviceInput *audioInput;
@property(nonatomic) NSMenu *audioMenu, *outputMenu, *pluginsMenu;
@property(nonatomic) AVCaptureMovieFileOutput *movieOutput;
@property(nonatomic, copy) NSString *videoCodec, *audioFormat, *outputDir;
@property(nonatomic) NSURL *lastRecording;
@property(nonatomic) BOOL quitAfterRecording;
@property(atomic) BOOL snapshotPending;  // set on main, consumed on the video queue
@property(nonatomic) NSWindow *window;
@property(nonatomic) ControlView *view;
@property(nonatomic) AVCaptureSession *session;
@property(nonatomic) AVCaptureDevice *videoDevice;           // nil with StackChan
@property(nonatomic) StackChanCamera *stackchan;             // set with -d stackchan
@property(nonatomic) AVSampleBufferDisplayLayer *displayLayer;  // shows StackChan frames
@property(nonatomic) NSMenu *resolutionMenu, *frameRateMenu;
@property(nonatomic) CMVideoDimensions size;
@property(nonatomic) double fps;
@end

static NSArray<AVCaptureDevice *> *devices(AVCaptureDeviceType type, AVMediaType media) {
  return [AVCaptureDeviceDiscoverySession
             discoverySessionWithDeviceTypes:@[ type ]
                                   mediaType:media
                                    position:AVCaptureDevicePositionUnspecified]
      .devices;
}

// Microphone covers every audio input on macOS 14+: built-in, USB interfaces, virtual devices.
static NSArray<AVCaptureDevice *> *audioDevices(void) {
  return devices(AVCaptureDeviceTypeMicrophone, AVMediaTypeAudio);
}

static AVCaptureDevice *findDevice(NSArray<AVCaptureDevice *> *list, NSString *name) {
  for (AVCaptureDevice *d in list)
    if ([d.localizedName rangeOfString:name options:NSCaseInsensitiveSearch].location != NSNotFound)
      return d;
  return nil;
}

static AVCaptureDevice *findCamera(void) {
  return findDevice(devices(AVCaptureDeviceTypeExternal, AVMediaTypeVideo), kDeviceName);
}

static BOOL sameSize(CMVideoDimensions a, CMVideoDimensions b) {
  return a.width == b.width && a.height == b.height;
}

// The Pocket 3 also lists '2vuy' formats (including the only 4K60 one), but
// measured on macOS they deliver zero frames; only '420v' formats stream.
static NSArray<AVCaptureDeviceFormat *> *usableFormats(AVCaptureDevice *d) {
  return [d.formats filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(
                                                     AVCaptureDeviceFormat *f, NSDictionary *b) {
    return CMFormatDescriptionGetMediaSubType(f.formatDescription) ==
           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
  }]];
}

// Distinct resolutions, landscape before portrait, small to large.
static NSArray<NSValue *> *availableSizes(AVCaptureDevice *d) {
  NSMutableArray<NSValue *> *sizes = [NSMutableArray array];
  for (AVCaptureDeviceFormat *f in usableFormats(d)) {
    CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
    NSValue *v = [NSValue valueWithBytes:&dim objCType:@encode(CMVideoDimensions)];
    if (![sizes containsObject:v]) [sizes addObject:v];
  }
  [sizes sortUsingComparator:^NSComparisonResult(NSValue *x, NSValue *y) {
    CMVideoDimensions a, b;
    [x getValue:&a];
    [y getValue:&b];
    BOOL pa = a.height > a.width, pb = b.height > b.width;
    if (pa != pb) return pa ? NSOrderedDescending : NSOrderedAscending;
    return a.width * a.height < b.width * b.height ? NSOrderedAscending : NSOrderedDescending;
  }];
  return sizes;
}

// Distinct frame rates offered for a resolution, highest first.
static NSArray<NSNumber *> *availableFrameRates(AVCaptureDevice *d, CMVideoDimensions size) {
  NSMutableSet<NSNumber *> *rates = [NSMutableSet set];
  for (AVCaptureDeviceFormat *f in usableFormats(d))
    if (sameSize(CMVideoFormatDescriptionGetDimensions(f.formatDescription), size))
      for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges)
        [rates addObject:@(round(r.maxFrameRate * 100) / 100)];
  return [rates.allObjects sortedArrayUsingSelector:@selector(compare:)].reverseObjectEnumerator.allObjects;
}

// Picks the usable format for size@fps, or nil.
static AVCaptureDeviceFormat *pickFormat(AVCaptureDevice *d, CMVideoDimensions size, double fps,
                                         AVFrameRateRange **rangeOut) {
  for (AVCaptureDeviceFormat *f in usableFormats(d)) {
    if (!sameSize(CMVideoFormatDescriptionGetDimensions(f.formatDescription), size)) continue;
    for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
      if (fps < r.minFrameRate - 0.01 || fps > r.maxFrameRate + 0.01) continue;
      if (rangeOut) *rangeOut = r;
      return f;
    }
  }
  return nil;
}

static NSString *sizeString(CMVideoDimensions s) {
  return [NSString stringWithFormat:@"%d×%d", s.width, s.height];
}

static NSString *fpsString(double fps) {
  fps = round(fps * 100) / 100;
  return fps == round(fps) ? [NSString stringWithFormat:@"%.0f", fps]
                           : [NSString stringWithFormat:@"%.2f", fps];
}

static NSString *optSize, *optFps, *optOutDir, *optAudio, *optCodec, *optDevice;
static double optRecordSecs;
static BOOL optEchoCancel;
static NSMutableArray<NSString *> *optPlugins;

// The StackChan's serial port for -d stackchan[:PORT] (found on USB when not
// given), else nil: the Pocket 3.
static NSString *stackChanPort(void) {
  static NSString *port;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    if ([optDevice isEqual:@"stackchan"]) port = stackchan_usb_port();
    if ([optDevice hasPrefix:@"stackchan:"]) port = [optDevice substringFromIndex:10];
  });
  return port;
}

// {UID, name} of every CoreAudio device that has output streams. The UID is what
// AVCaptureAudioPreviewOutput.outputDeviceUniqueID takes.
static NSArray<NSArray<NSString *> *> *outputDevices(void) {
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};
  UInt32 size = 0;
  if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size)) return @[];
  NSMutableData *ids = [NSMutableData dataWithLength:size];
  if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids.mutableBytes))
    return @[];

  NSMutableArray *result = [NSMutableArray array];
  const AudioObjectID *dev = ids.bytes;
  for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) {
    AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput,
                                          kAudioObjectPropertyElementMain};
    UInt32 streamsSize = 0;
    if (AudioObjectGetPropertyDataSize(dev[i], &streams, 0, NULL, &streamsSize) || !streamsSize) continue;

    AudioObjectPropertyAddress prop = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal,
                                       kAudioObjectPropertyElementMain};
    CFStringRef uid = NULL, name = NULL;
    UInt32 sz = sizeof uid;
    if (AudioObjectGetPropertyData(dev[i], &prop, 0, NULL, &sz, &uid) || !uid) continue;
    prop.mSelector = kAudioObjectPropertyName;
    sz = sizeof name;
    AudioObjectGetPropertyData(dev[i], &prop, 0, NULL, &sz, &name);
    NSString *uidStr = CFBridgingRelease(uid);
    [result addObject:@[ uidStr, name ? (NSString *)CFBridgingRelease(name) : uidStr ]];
  }
  return result;
}

// Recording choices; each row is {key, menu title}. Keys persist in NSUserDefaults.
static NSString *const kDefaultsVideoCodec = @"videoCodec";
static NSString *const kDefaultsAudioFormat = @"audioFormat";
static NSString *const kDefaultsOutputDir = @"outputDir";
// "off", "default" (system output) or a CoreAudio device UID.
static NSString *const kDefaultsMonitor = @"monitorOutput";
static NSString *const kDefaultsPluginSettings = @"pluginSettings";  // plugin name -> {key: value}

static NSArray<NSArray<NSString *> *> *videoCodecChoices(void) {
  return @[ @[ @"hevc", @"HEVC (H.265)" ], @[ @"h264", @"H.264" ], @[ @"prores", @"Apple ProRes 422" ] ];
}

static NSArray<NSArray<NSString *> *> *audioFormatChoices(void) {
  return @[
    @[ @"aac128", @"AAC 128 kbps" ], @[ @"aac256", @"AAC 256 kbps" ], @[ @"aac320", @"AAC 320 kbps" ],
    @[ @"pcm", @"Linear PCM 24-bit (lossless)" ]
  ];
}

static AVVideoCodecType videoCodecType(NSString *key) {
  if ([key isEqual:@"h264"]) return AVVideoCodecTypeH264;
  if ([key isEqual:@"prores"]) return AVVideoCodecTypeAppleProRes422;
  return AVVideoCodecTypeHEVC;
}

// Everything is stereo: multichannel inputs (e.g. BlackHole 64ch) mix down.
static NSDictionary *audioSettings(NSString *key) {
  if ([key isEqual:@"pcm"])
    return @{
      AVFormatIDKey : @(kAudioFormatLinearPCM),
      AVNumberOfChannelsKey : @2,
      AVSampleRateKey : @48000,
      AVLinearPCMBitDepthKey : @24,
      AVLinearPCMIsFloatKey : @NO,
      AVLinearPCMIsBigEndianKey : @NO,
      AVLinearPCMIsNonInterleaved : @NO,
    };
  int kbps = [key hasPrefix:@"aac"] ? [key substringFromIndex:3].intValue : 256;
  return @{
    AVFormatIDKey : @(kAudioFormatMPEG4AAC),
    AVNumberOfChannelsKey : @2,
    AVEncoderBitRateKey : @(kbps * 1000)
  };
}

static NSString *titleForKey(NSArray<NSArray<NSString *> *> *choices, NSString *key) {
  for (NSArray<NSString *> *c in choices)
    if ([c[0] isEqual:key]) return c[1];
  return nil;
}

@implementation AppDelegate {
  CMVideoDimensions _streamSize;     // StackChan queue only
  double _fpsWindowStart;            // StackChan queue only
  int _fpsFrames;                    // StackChan queue only
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  if (stackChanPort()) {  // video comes over the serial link: no camera access needed
    if ([optAudio isEqual:@"none"]) {
      [self startWithAudio:NO];
      return;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL audioOK) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self startWithAudio:audioOK];
      });
    }];
    return;
  }
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL videoOK) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL audioOK) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!videoOK) {
          NSLog(@"camera access denied: enable it for your terminal in System Settings → "
                @"Privacy & Security → Camera");
          [NSApp terminate:nil];
        }
        [self startWithAudio:audioOK];
      });
    }];
  }];
}

- (void)startWithAudio:(BOOL)audioOK {
  NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
  self.videoCodec = optCodec ?: [defaults stringForKey:kDefaultsVideoCodec] ?: @"hevc";
  self.audioFormat = [defaults stringForKey:kDefaultsAudioFormat] ?: @"aac256";
  self.outputDir = optOutDir.stringByExpandingTildeInPath ?: [defaults stringForKey:kDefaultsOutputDir]
                       ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Movies"];
  if (!titleForKey(videoCodecChoices(), self.videoCodec)) {
    NSLog(@"unknown codec %@ (use hevc, h264 or prores)", self.videoCodec);
    [NSApp terminate:nil];
  }

  // With StackChan the session carries audio only; video comes over its link.
  AVCaptureDevice *video = nil;
  if (!stackChanPort()) {
    video = findCamera();
    if (!video) {
      NSLog(@"%@ camera not found", kDeviceName);
      [NSApp terminate:nil];
    }
  }

  AVCaptureSession *session = [AVCaptureSession new];
  NSError *err;
  if (video) {
    AVCaptureDeviceInput *vin = [AVCaptureDeviceInput deviceInputWithDevice:video error:&err];
    if (!vin) {
      NSLog(@"video input: %@", err);
      [NSApp terminate:nil];
    }
    [session addInput:vin];
    // On macOS the session re-applies its preset (and resets the camera to its
    // default format) on startRunning and on every configuration commit, unless
    // the device is locked for configuration. Hold the lock for the app's lifetime.
    if (![video lockForConfiguration:&err]) {
      NSLog(@"cannot lock camera for configuration: %@", err.localizedDescription);
      [NSApp terminate:nil];
    }
  }

  // Audio monitoring is off unless an output was chosen in the Audio Output menu (or m pressed).
  AVCaptureAudioPreviewOutput *monitor = [AVCaptureAudioPreviewOutput new];
  monitor.volume = 0;
  if ([session canAddOutput:monitor]) [session addOutput:monitor];
  self.monitor = monitor;
  NSString *monitorChoice = [NSUserDefaults.standardUserDefaults stringForKey:kDefaultsMonitor] ?: @"off";
  BOOL present = [monitorChoice isEqual:@"off"] || [monitorChoice isEqual:@"default"];
  for (NSArray<NSString *> *o in outputDevices()) present = present || [o[0] isEqual:monitorChoice];
  if (!present) monitorChoice = @"off";  // remembered device is unplugged; stay silent
  self.monitorSetting = monitorChoice;
  self.echoCancel = optEchoCancel;

  // Raw frames and audio for plugins (and video for the echo-cancel writer).
  AVCaptureVideoDataOutput *videoData = [AVCaptureVideoDataOutput new];
  videoData.alwaysDiscardsLateVideoFrames = NO;  // the writer needs every frame; plugins drop their own
  [videoData setSampleBufferDelegate:self queue:dispatch_queue_create("video", DISPATCH_QUEUE_SERIAL)];
  if ([session canAddOutput:videoData]) {
    [session addOutput:videoData];
    self.videoData = videoData;
  }
  AVCaptureAudioDataOutput *audioData = [AVCaptureAudioDataOutput new];
  // One predictable format whatever the input: multichannel devices (e.g.
  // BlackHole 64ch) are mixed to stereo here instead of in every consumer.
  audioData.audioSettings = @{
    AVFormatIDKey : @(kAudioFormatLinearPCM),
    AVSampleRateKey : @48000,
    AVNumberOfChannelsKey : @2,
    AVLinearPCMBitDepthKey : @32,
    AVLinearPCMIsFloatKey : @YES,
    AVLinearPCMIsNonInterleaved : @NO,
  };
  [audioData setSampleBufferDelegate:self queue:dispatch_queue_create("audio", DISPATCH_QUEUE_SERIAL)];
  if ([session canAddOutput:audioData]) {
    [session addOutput:audioData];
    self.audioData = audioData;
  }

  AVCaptureMovieFileOutput *movie = [AVCaptureMovieFileOutput new];
  if (!video) {
    // StackChan frames never enter the session; they are recorded with the writer.
  } else if ([session canAddOutput:movie]) {
    [session addOutput:movie];
    self.movieOutput = movie;
  } else {
    NSLog(@"recording unavailable: cannot add movie output");
  }

  NSRect frame = NSMakeRect(0, 0, 1280, 720);
  self.window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
                  backing:NSBackingStoreBuffered
                    defer:NO];
  self.window.title = [NSString stringWithFormat:@"%@ — arrows/drag: move, scroll: zoom, "
                                                 @"c: center, ,/.: roll, r: record, m: audio, v: scaling, f: fullscreen",
                                                 video ? video.localizedName : @"StackChan"];

  ControlView *view = [[ControlView alloc] initWithFrame:frame];
  view.session = session;
  view.monitor = monitor;
  CALayer<VideoLayer> *preview;
  if (video) {
    preview = [AVCaptureVideoPreviewLayer layerWithSession:session];
  } else {
    self.displayLayer = [AVSampleBufferDisplayLayer new];
    preview = self.displayLayer;
  }
  preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
  view.preview = preview;
  view.overlay.preview = preview;
  __weak AppDelegate *weakSelf = self;
  view.menuProvider = ^NSMenu * { return [weakSelf contextMenu]; };
  view.inputHandler = ^(NSDictionary *event) { [weakSelf.plugins broadcastInput:event]; };
  preview.frame = view.bounds;
  preview.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  [view.layer insertSublayer:preview atIndex:0];

  self.window.contentView = view;
  self.view = view;
  self.session = session;
  self.videoDevice = video;
  [self buildMenus];

  if (audioOK) {
    AVCaptureDevice *audio = video || optAudio ? findDevice(audioDevices(), optAudio ?: kDeviceName)
                                               : [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    if (audio)
      [self useAudioDevice:audio];
    else
      NSLog(@"audio input \"%@\" not found, running video only (run with -l to list inputs)",
            optAudio ?: kDeviceName);
  } else if ([optAudio isEqual:@"none"]) {
    NSLog(@"audio off (-a none), running video only");
  } else {
    NSLog(@"microphone access denied, running video only");
  }

  if (video) {
    CMVideoDimensions size = {1920, 1080};
    int w, h;
    if (optSize && sscanf(optSize.UTF8String, "%dx%d", &w, &h) == 2) size = (CMVideoDimensions){w, h};
    double fps = optFps ? optFps.doubleValue : 0;
    if (![self applySize:size fps:fps]) {
      NSLog(@"%@@%@ not supported, run with -l to list formats", sizeString(size), optFps ?: @"max");
      [NSApp terminate:nil];
    }
  } else {
    self.view.formatInfo = @"connecting to StackChan…";
    self.stackchan = [[StackChanCamera alloc] initWithPort:stackChanPort()];
    __weak AppDelegate *weakSelf = self;
    [self.stackchan startWithHandler:^(CMSampleBufferRef frame) {
      [weakSelf stackChanFrame:frame];
    }];
  }

  [self.window center];
  [self.window makeKeyAndOrderFront:nil];
  [self.window makeFirstResponder:view];
  [NSApp activateIgnoringOtherApps:YES];

  [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification
                                                  object:session
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification *n) {
    NSLog(@"capture session error: %@", n.userInfo[AVCaptureSessionErrorKey]);
  }];
  [self startPlugins];

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [session startRunning];
    // Give the camera a moment to deliver frames; recording started before the
    // first frame arrives can fail with "Cannot Record".
    if (optRecordSecs > 0)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self toggleRecording:nil];
      });
  });
}

// Switches the camera to size@fps (fps 0 = highest available). Returns NO if unsupported.
- (BOOL)applySize:(CMVideoDimensions)size fps:(double)fps {
  if (fps <= 0) fps = availableFrameRates(self.videoDevice, size).firstObject.doubleValue;
  AVFrameRateRange *range;
  AVCaptureDeviceFormat *format = pickFormat(self.videoDevice, size, fps, &range);
  if (!format) return NO;

  // The device stays locked for configuration (see startWithAudio), so this
  // format survives session start and later reconfiguration.
  [self.session beginConfiguration];
  self.videoDevice.activeFormat = format;
  // Exact frame duration from the range avoids rounding (e.g. 29.97 vs 30).
  CMTime duration = fabs(range.maxFrameRate - fps) < 0.01 ? range.minFrameDuration
                                                          : CMTimeMakeWithSeconds(1 / fps, 1000000);
  self.videoDevice.activeVideoMinFrameDuration = duration;
  self.videoDevice.activeVideoMaxFrameDuration = duration;
  [self.session commitConfiguration];
  CMVideoDimensions active = CMVideoFormatDescriptionGetDimensions(
      self.videoDevice.activeFormat.formatDescription);
  NSLog(@"video format: %@ @ %@ fps", sizeString(active),
        fpsString(1 / CMTimeGetSeconds(self.videoDevice.activeVideoMinFrameDuration)));

  BOOL orientationChanged = (size.height > size.width) != (self.size.height > self.size.width) ||
                            self.size.width == 0;
  self.size = size;
  self.fps = fps;
  self.view.formatInfo = [NSString stringWithFormat:@"%@@%@", sizeString(size), fpsString(fps)];
  self.view.overlay.videoSize = CGSizeMake(size.width, size.height);
  if (orientationChanged) [self fitWindowToSize:size];
  [self updateMenus];
  return YES;
}

- (void)fitWindowToSize:(CMVideoDimensions)size {
  if (self.window.styleMask & NSWindowStyleMaskFullScreen) return;
  NSRect visible = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
  double h = size.height > size.width ? visible.size.height * 0.9 : 720;
  double w = h * size.width / size.height;
  NSRect frame = self.window.frame;
  NSRect content = [self.window frameRectForContentRect:NSMakeRect(0, 0, w, h)];
  frame.origin.y += frame.size.height - content.size.height;  // keep the title bar in place
  frame.size = content.size;
  [self.window setFrame:NSIntersectionRect(frame, visible).size.height == frame.size.height
                            ? frame
                            : NSMakeRect(NSMidX(visible) - w / 2, NSMinY(visible), content.size.width,
                                         content.size.height)
                display:YES
                animate:YES];
}

- (void)buildMenus {
  NSMenu *main = [NSMenu new];
  NSMenuItem *appItem = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
  appItem.submenu = [NSMenu new];
  [appItem.submenu addItemWithTitle:@"Quit pocket-viewer" action:@selector(terminate:) keyEquivalent:@"q"];

  // Resolution and Record are static so their ⌘ shortcuts always work; the
  // device lists are rebuilt on open (menuNeedsUpdate) to catch hot-plugging.
  self.resolutionMenu = [[NSMenu alloc] initWithTitle:@"Resolution"];
  [self fillResolutionMenu:self.resolutionMenu];
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = self.resolutionMenu;

  self.frameRateMenu = [[NSMenu alloc] initWithTitle:@"Frame Rate"];
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = self.frameRateMenu;

  self.audioMenu = [[NSMenu alloc] initWithTitle:@"Audio Input"];
  self.audioMenu.delegate = self;
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = self.audioMenu;

  self.outputMenu = [[NSMenu alloc] initWithTitle:@"Audio Output"];
  self.outputMenu.delegate = self;
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = self.outputMenu;

  self.pluginsMenu = [[NSMenu alloc] initWithTitle:@"Plugins"];
  self.pluginsMenu.delegate = self;
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = self.pluginsMenu;

  NSMenu *recordMenu = [[NSMenu alloc] initWithTitle:@"Record"];
  [self addRecordToggleTo:recordMenu];
  [recordMenu addItem:NSMenuItem.separatorItem];
  [self fillRecordSettingsMenu:recordMenu];
  [main addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = recordMenu;
  NSApp.mainMenu = main;
}

// The right-click menu: everything from the menu bar plus view controls, built
// fresh on each click from the same fill methods.
- (NSMenu *)contextMenu {
  NSMenu *m = [NSMenu new];
  [self addRecordToggleTo:m];
  [self fillRecordSettingsMenu:[self addSubmenu:@"Recording Settings" to:m]];
  [m addItem:NSMenuItem.separatorItem];
  [self fillResolutionMenu:[self addSubmenu:@"Resolution" to:m]];
  [self fillFrameRateMenu:[self addSubmenu:@"Frame Rate" to:m]];
  [m addItem:NSMenuItem.separatorItem];
  [self fillAudioInputMenu:[self addSubmenu:@"Audio Input" to:m]];
  [self fillOutputMenu:[self addSubmenu:@"Audio Output (Monitor)" to:m]];
  [m addItem:NSMenuItem.separatorItem];
  [self fillPluginsMenu:[self addSubmenu:@"Plugins" to:m]];
  [m addItem:NSMenuItem.separatorItem];
  // Untargeted items go to the view / window through the responder chain.
  [self.view fillGravityMenu:[self addSubmenu:@"Video Scaling" to:m]];
  [m addItemWithTitle:@"Center Gimbal" action:@selector(centerGimbal:) keyEquivalent:@""];
  [m addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@""];
  [m addItem:NSMenuItem.separatorItem];
  [m addItemWithTitle:@"Quit pocket-viewer" action:@selector(terminate:) keyEquivalent:@""];
  return m;
}

- (NSMenu *)addSubmenu:(NSString *)title to:(NSMenu *)menu {
  NSMenu *sub = [[NSMenu alloc] initWithTitle:title];
  [menu addItemWithTitle:title action:nil keyEquivalent:@""].submenu = sub;
  return sub;
}

- (void)addRecordToggleTo:(NSMenu *)menu {
  // Title (Start/Stop) is set in validateMenuItem.
  [menu addItemWithTitle:@"Start Recording" action:@selector(toggleRecording:) keyEquivalent:@"r"].target = self;
}

- (void)fillRecordSettingsMenu:(NSMenu *)menu {
  NSMenuItem *codecItem = [menu addItemWithTitle:@"Video Codec" action:nil keyEquivalent:@""];
  codecItem.submenu = [NSMenu new];
  for (NSArray<NSString *> *c in videoCodecChoices())
    [self addChoice:c to:codecItem.submenu action:@selector(chooseVideoCodec:)];

  NSMenuItem *audioItem = [menu addItemWithTitle:@"Audio Format" action:nil keyEquivalent:@""];
  audioItem.submenu = [NSMenu new];
  for (NSArray<NSString *> *c in audioFormatChoices())
    [self addChoice:c to:audioItem.submenu action:@selector(chooseAudioFormat:)];

  [menu addItem:NSMenuItem.separatorItem];
  // Title ("Save to: <dir>…") is set in validateMenuItem.
  [menu addItemWithTitle:@"Save to…" action:@selector(chooseFolder:) keyEquivalent:@""].target = self;
  [menu addItemWithTitle:@"Show in Finder" action:@selector(showInFinder:) keyEquivalent:@""].target = self;
}

- (void)fillResolutionMenu:(NSMenu *)menu {
  NSArray<NSValue *> *sizes = availableSizes(self.videoDevice);
  for (NSUInteger i = 0; i < sizes.count; i++) {
    CMVideoDimensions s;
    [sizes[i] getValue:&s];
    NSString *title = [NSString stringWithFormat:@"%@%@  (up to %@ fps)", sizeString(s),
                                                 s.height > s.width ? @" portrait" : @"",
                                                 fpsString(availableFrameRates(self.videoDevice, s)
                                                               .firstObject.doubleValue)];
    NSMenuItem *item = [menu addItemWithTitle:title
                                       action:@selector(chooseResolution:)
                                keyEquivalent:i < 9 ? [NSString stringWithFormat:@"%lu", i + 1] : @""];
    item.target = self;
    item.representedObject = sizes[i];
  }
}

- (void)fillFrameRateMenu:(NSMenu *)menu {
  for (NSNumber *rate in availableFrameRates(self.videoDevice, self.size)) {
    NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithFormat:@"%@ fps", fpsString(rate.doubleValue)]
                                       action:@selector(chooseFrameRate:)
                                keyEquivalent:@""];
    item.target = self;
    item.representedObject = rate;
  }
}

- (void)fillAudioInputMenu:(NSMenu *)menu {
  [menu addItemWithTitle:@"None" action:@selector(chooseAudioInput:) keyEquivalent:@""].target = self;
  for (AVCaptureDevice *dev in audioDevices()) {
    NSMenuItem *item = [menu addItemWithTitle:dev.localizedName
                                       action:@selector(chooseAudioInput:)
                                keyEquivalent:@""];
    item.target = self;
    item.representedObject = dev;
  }
}

- (void)fillOutputMenu:(NSMenu *)menu {
  [menu addItemWithTitle:@"Echo Cancellation (experimental)" action:@selector(toggleEchoCancel:) keyEquivalent:@""]
      .target = self;
  [menu addItem:NSMenuItem.separatorItem];
  NSMutableArray *choices = [NSMutableArray arrayWithObjects:@[ @"off", @"Monitor Off" ],
                                                             @[ @"default", @"System Default Output" ], nil];
  [choices addObjectsFromArray:outputDevices()];
  for (NSArray<NSString *> *c in choices) {
    NSString *title = c[1];
    // Playing an input back into the same device (e.g. BlackHole) loops it straight back in.
    if ([c[0] isEqual:self.selectedAudio.uniqueID])
      title = [title stringByAppendingString:@"  — same device as input, may echo"];
    NSMenuItem *item = [menu addItemWithTitle:title action:@selector(chooseMonitorOutput:) keyEquivalent:@""];
    item.target = self;
    item.representedObject = c[0];
    if (c == choices[1]) [menu addItem:NSMenuItem.separatorItem];
  }
}

- (void)updateMenus {
  [self.frameRateMenu removeAllItems];
  [self fillFrameRateMenu:self.frameRateMenu];
}

- (void)chooseResolution:(NSMenuItem *)item {
  CMVideoDimensions s;
  [item.representedObject getValue:&s];
  // Keep the current frame rate if the new resolution offers it, else use its highest.
  double fps = [availableFrameRates(self.videoDevice, s) containsObject:@(self.fps)] ? self.fps : 0;
  [self applySize:s fps:fps];
}

- (void)chooseFrameRate:(NSMenuItem *)item {
  [self applySize:self.size fps:[item.representedObject doubleValue]];
}

- (BOOL)useAudioDevice:(AVCaptureDevice *)device {
  self.selectedAudio = device;
  [self applyAudioRouting];
  NSLog(@"audio input: %@", device ? device.localizedName : @"none");
  return YES;
}

// Normal mode: the selected input feeds the capture session (preview monitor,
// movie file output). Echo-cancel mode: the input is taken away from the
// session and captured by the EchoCanceller instead, whose processed audio is
// monitored and recorded (with camera frames from a video data output).
- (void)applyAudioRouting {
  BOOL ec = self.echoCancel && self.selectedAudio;
  [self.session beginConfiguration];
  if (self.audioInput && (ec || ![self.audioInput.device isEqual:self.selectedAudio])) {
    [self.session removeInput:self.audioInput];
    self.audioInput = nil;
  }
  if (!ec && self.selectedAudio && !self.audioInput) {
    NSError *err;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:self.selectedAudio error:&err];
    if (input && [self.session canAddInput:input]) {
      [self.session addInput:input];
      self.audioInput = input;
    } else {
      NSLog(@"audio input %@: %@", self.selectedAudio.localizedName, err.localizedDescription ?: @"cannot add");
    }
  }
  [self.session commitConfiguration];
  self.view.audioConnection = [self.monitor connectionWithMediaType:AVMediaTypeAudio];
  [self applyMonitor];
}

- (void)applyMonitor {
  NSString *setting = self.monitorSetting;
  BOOL on = ![setting isEqual:@"off"];
  NSString *outputUID = on && ![setting isEqual:@"default"] ? setting : nil;

  if (self.echoCancel && self.selectedAudio) {
    self.monitor.volume = 0;
    BOOL sameDevices = self.ec && [self.ecInputUID isEqual:self.selectedAudio.uniqueID] &&
                       (self.ecOutputUID == outputUID || [self.ecOutputUID isEqual:outputUID]);
    if (sameDevices) {
      self.ec.monitoring = on;
    } else {
      if (!self.ec) {
        self.ec = [EchoCanceller new];
        __weak AppDelegate *weakSelf = self;
        self.ec.onAudio = ^(CMSampleBufferRef buf) {
          [weakSelf.writer appendAudio:buf];
          [weakSelf.plugins pushAudio:buf];
        };
      }
      NSError *err;
      if ([self.ec startWithInputUID:self.selectedAudio.uniqueID outputUID:outputUID monitoring:on error:&err]) {
        self.ecInputUID = self.selectedAudio.uniqueID;
        self.ecOutputUID = outputUID;
        NSLog(@"echo cancellation on: %@ → %@", self.selectedAudio.localizedName, outputUID ?: @"system default output");
      } else {
        NSLog(@"echo cancellation failed, back to normal audio: %@", err.localizedDescription);
        [self.ec stop];
        self.ec = nil;
        self.echoCancel = NO;
        [self applyAudioRouting];
        return;
      }
    }
  } else {
    [self.ec stop];
    self.ec = nil;
    self.ecInputUID = self.ecOutputUID = nil;
    if (on) self.monitor.outputDeviceUniqueID = outputUID;
    self.monitor.volume = on ? 1 : 0;
  }
  self.view.echoCanceller = self.ec;
  self.view.monitoring = on;
}

- (void)toggleEchoCancel:(id)sender {
  self.echoCancel = !self.echoCancel;
  [self applyAudioRouting];
}

- (void)toggleMonitor:(id)sender {
  if ([self.monitorSetting isEqual:@"off"]) {
    self.monitorSetting = self.lastMonitorOn ?: @"default";
  } else {
    self.lastMonitorOn = self.monitorSetting;
    self.monitorSetting = @"off";
  }
  [self applyMonitor];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  if (menu == self.outputMenu)
    [self fillOutputMenu:menu];
  else if (menu == self.pluginsMenu)
    [self fillPluginsMenu:menu];
  else
    [self fillAudioInputMenu:menu];
}

- (void)chooseMonitorOutput:(NSMenuItem *)item {
  self.monitorSetting = item.representedObject;
  [NSUserDefaults.standardUserDefaults setObject:item.representedObject forKey:kDefaultsMonitor];
  [self applyMonitor];
}

- (void)chooseAudioInput:(NSMenuItem *)item {
  [self useAudioDevice:item.representedObject];
}

- (void)addChoice:(NSArray<NSString *> *)choice to:(NSMenu *)menu action:(SEL)action {
  NSMenuItem *item = [menu addItemWithTitle:choice[1] action:action keyEquivalent:@""];
  item.target = self;
  item.representedObject = choice[0];
}

- (void)chooseVideoCodec:(NSMenuItem *)item {
  self.videoCodec = item.representedObject;
  [NSUserDefaults.standardUserDefaults setObject:self.videoCodec forKey:kDefaultsVideoCodec];
}

- (void)chooseAudioFormat:(NSMenuItem *)item {
  self.audioFormat = item.representedObject;
  [NSUserDefaults.standardUserDefaults setObject:self.audioFormat forKey:kDefaultsAudioFormat];
}

- (void)chooseFolder:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = YES;
  panel.canChooseFiles = NO;
  panel.canCreateDirectories = YES;
  panel.prompt = @"Save Here";
  panel.directoryURL = [NSURL fileURLWithPath:self.outputDir];
  [panel beginSheetModalForWindow:self.window
                completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK) return;
    self.outputDir = panel.URL.path;
    [NSUserDefaults.standardUserDefaults setObject:self.outputDir forKey:kDefaultsOutputDir];
  }];
}

- (void)showInFinder:(id)sender {
  if (self.lastRecording)
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ self.lastRecording ]];
  else
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.outputDir]];
}

// Sets every item's checkmark / title from current state, so the menu bar and
// the right-click menu always agree.
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  SEL a = item.action;
  BOOL recording = self.isRecording;
  BOOL on = NO;
  if (a == @selector(chooseResolution:)) {
    CMVideoDimensions s;
    [item.representedObject getValue:&s];
    on = sameSize(s, self.size);
  } else if (a == @selector(chooseFrameRate:)) {
    on = fabs([item.representedObject doubleValue] - self.fps) < 0.01;
  } else if (a == @selector(chooseAudioInput:)) {
    AVCaptureDevice *dev = item.representedObject;
    on = dev ? [dev.uniqueID isEqual:self.selectedAudio.uniqueID] : !self.selectedAudio;
  } else if (a == @selector(chooseMonitorOutput:)) {
    on = [item.representedObject isEqual:self.monitorSetting];
  } else if (a == @selector(chooseVideoCodec:)) {
    on = [item.representedObject isEqual:self.videoCodec];
  } else if (a == @selector(chooseAudioFormat:)) {
    on = [item.representedObject isEqual:self.audioFormat];
  } else if (a == @selector(chooseFolder:)) {
    item.title = [NSString stringWithFormat:@"Save to: %@…", self.outputDir.stringByAbbreviatingWithTildeInPath];
  } else if (a == @selector(toggleEchoCancel:)) {
    item.state = self.echoCancel ? NSControlStateValueOn : NSControlStateValueOff;
    return !recording && self.selectedAudio;
  } else if (a == @selector(toggleRecording:)) {
    item.title = recording ? @"Stop Recording" : @"Start Recording";
    return self.movieOutput != nil || (self.stackchan && self.size.width > 0);
  }
  item.state = on ? NSControlStateValueOn : NSControlStateValueOff;

  // The format, tracks and file settings can't change mid-file, so lock them while recording.
  if (a == @selector(chooseResolution:) || a == @selector(chooseFrameRate:) ||
      a == @selector(chooseAudioInput:) || a == @selector(chooseVideoCodec:) ||
      a == @selector(chooseAudioFormat:) || a == @selector(chooseFolder:))
    return !recording;
  return YES;
}

- (BOOL)isRecording {
  return self.movieOutput.isRecording || self.writer;
}

- (void)toggleRecording:(id)sender {
  AVCaptureMovieFileOutput *out = self.movieOutput;
  if (!out && !self.stackchan) return;
  if (self.isRecording) {
    if (self.writer)
      [self finishWriter];
    else
      [out stopRecording];
    return;
  }

  NSString *dir = self.outputDir;
  NSError *err;
  if (![NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err]) {
    NSLog(@"cannot create %@: %@", dir, err.localizedDescription);
    return;
  }
  NSDateFormatter *df = [NSDateFormatter new];
  df.dateFormat = @"yyyyMMdd-HHmmss";
  NSString *name = [NSString stringWithFormat:@"pocket-viewer-%@.mov", [df stringFromDate:NSDate.date]];
  NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]];

  if (self.ec || self.stackchan) {
    // Echo-cancelled audio and StackChan video never reach the capture session's
    // movie output, so mux them ourselves.
    NSDictionary *video = @{
      AVVideoCodecKey : videoCodecType(self.videoCodec),
      AVVideoWidthKey : @(self.size.width),
      AVVideoHeightKey : @(self.size.height)
    };
    NSMutableDictionary *audio = [audioSettings(self.audioFormat) mutableCopy];
    audio[AVSampleRateKey] = @48000;  // the writer, unlike the movie output, needs it explicit
    MovieWriter *writer = [[MovieWriter alloc] initWithURL:url videoSettings:video audioSettings:audio error:&err];
    if (!writer) {
      NSLog(@"recording FAILED: %@", err.localizedDescription);
      if (optRecordSecs > 0) exit(1);
      return;
    }
    self.writer = writer;
    [self recordingStarted:url];
    return;
  }

  AVCaptureConnection *vconn = [out connectionWithMediaType:AVMediaTypeVideo];
  if (vconn)
    [out setOutputSettings:@{AVVideoCodecKey : videoCodecType(self.videoCodec)} forConnection:vconn];
  AVCaptureConnection *aconn = [out connectionWithMediaType:AVMediaTypeAudio];
  if (aconn) [out setOutputSettings:audioSettings(self.audioFormat) forConnection:aconn];
  [out startRecordingToOutputFileURL:url recordingDelegate:self];
}

- (void)finishWriter {
  if (self.finishingWriter) return;
  self.finishingWriter = YES;
  MovieWriter *writer = self.writer;
  [writer finishWithCompletion:^(NSError *error) {
    self.writer = nil;
    self.finishingWriter = NO;
    [self recordingFinished:writer.url error:error ok:!error];
  }];
}

// A StackChan frame (on its queue, already on the host clock): shown, and handed
// on like the Pocket 3 frames in captureOutput.
- (void)stackChanFrame:(CMSampleBufferRef)frame {
  CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(frame);
  CMVideoDimensions size = {(int32_t)CVPixelBufferGetWidth(pb), (int32_t)CVPixelBufferGetHeight(pb)};
  if (!sameSize(size, _streamSize)) {
    _streamSize = size;
    dispatch_async(dispatch_get_main_queue(), ^{
      self.size = size;
      self.view.overlay.videoSize = CGSizeMake(size.width, size.height);
      [self fitWindowToSize:size];
    });
  }
  double now = CACurrentMediaTime();
  _fpsFrames++;
  if (now - _fpsWindowStart >= 1) {
    double fps = _fpsFrames / (now - _fpsWindowStart);
    _fpsWindowStart = now;
    _fpsFrames = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
      self.fps = fps;
      self.view.formatInfo = [NSString stringWithFormat:@"%@@%.0f", sizeString(size), fps];
    });
  }

  AVSampleBufferVideoRenderer *renderer = self.displayLayer.sampleBufferRenderer;
  if (renderer.status == AVQueuedSampleBufferRenderingStatusFailed) [renderer flush];
  [renderer enqueueSampleBuffer:frame];
  if (self.snapshotPending) {
    self.snapshotPending = NO;
    [self saveSnapshot:pb];
  }
  [self.writer appendVideo:frame];
  [self.plugins pushVideo:frame];
}

// Camera frames and session audio. Everything handed on is restamped onto the
// host clock, which the echo-cancelled audio already uses.
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)buffer
           fromConnection:(AVCaptureConnection *)connection {
  // The writer records session audio too when the video is StackChan's.
  MovieWriter *writer = output == self.videoData || self.stackchan ? self.writer : nil;
  if (!writer && !self.plugins) return;
  CMSampleBufferRef hostTimed = NULL;
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(buffer);
  CMTime host = CMSyncConvertTime(pts, self.session.synchronizationClock, CMClockGetHostTimeClock());
  if (CMTimeCompare(host, pts) == 0) {
    hostTimed = (CMSampleBufferRef)CFRetain(buffer);
  } else {
    CMSampleTimingInfo timing;
    CMSampleBufferGetSampleTimingInfo(buffer, 0, &timing);
    timing.presentationTimeStamp = host;
    timing.decodeTimeStamp = kCMTimeInvalid;
    if (CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, buffer, 1, &timing, &hostTimed)) return;
  }
  if (output == self.videoData && self.snapshotPending) {
    self.snapshotPending = NO;
    [self saveSnapshot:CMSampleBufferGetImageBuffer(buffer)];
  }
  if (output == self.videoData) {
    [writer appendVideo:hostTimed];
    [self.plugins pushVideo:hostTimed];
  } else {
    [writer appendAudio:hostTimed];
    [self.plugins pushAudio:hostTimed];
  }
  CFRelease(hostTimed);
}

// Saves one full-resolution frame as a JPEG next to the recordings. Any queue.
- (void)saveSnapshot:(CVPixelBufferRef)pb {
  if (!pb) return;
  CIImage *image = [CIImage imageWithCVPixelBuffer:pb];
  NSDateFormatter *df = [NSDateFormatter new];
  df.dateFormat = @"yyyyMMdd-HHmmss-SSS";
  NSString *dir = self.outputDir;
  NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:
      [NSString stringWithFormat:@"pocket-viewer-%@.jpg", [df stringFromDate:NSDate.date]]]];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    NSError *err;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    BOOL ok = [[CIContext contextWithOptions:nil]
        writeJPEGRepresentationOfImage:image
                                 toURL:url
                            colorSpace:srgb
                               options:@{(id)kCGImageDestinationLossyCompressionQuality : @0.92}
                                 error:&err];
    CGColorSpaceRelease(srgb);
    NSLog(@"snapshot %@: %@%@", ok ? @"saved" : @"FAILED", url.path,
          err ? [@"  " stringByAppendingString:err.localizedDescription] : @"");
  });
}

- (void)recordingStarted:(NSURL *)url {
  NSLog(@"recording to %@ (%@, %@%@)", url.path, titleForKey(videoCodecChoices(), self.videoCodec),
        titleForKey(audioFormatChoices(), self.audioFormat), self.ec ? @", echo-cancelled" : @"");
  self.view.recordingSince = NSDate.date;
  if (optRecordSecs > 0)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(optRecordSecs * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     [NSApp terminate:nil];
                   });
}

- (void)recordingFinished:(NSURL *)url error:(NSError *)error ok:(BOOL)ok {
  NSLog(@"recording %@: %@%@", ok ? @"saved" : @"FAILED", url.path,
        error ? [@"  " stringByAppendingString:error.localizedDescription] : @"");
  self.view.recordingSince = nil;
  if (ok) self.lastRecording = url;
  if (self.quitAfterRecording) [NSApp terminate:nil];
  if (!ok && optRecordSecs > 0) exit(1);  // timed mode: report failure instead of idling
}

- (void)captureOutput:(AVCaptureFileOutput *)output
    didStartRecordingToOutputFileAtURL:(NSURL *)url
                       fromConnections:(NSArray<AVCaptureConnection *> *)connections {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self recordingStarted:url];
  });
}

- (void)captureOutput:(AVCaptureFileOutput *)output
    didFinishRecordingToOutputFileAtURL:(NSURL *)url
                        fromConnections:(NSArray<AVCaptureConnection *> *)connections
                                  error:(NSError *)error {
  dispatch_async(dispatch_get_main_queue(), ^{
    // An error can still leave a playable file (e.g. disk nearly full); report both.
    [self recordingFinished:url
                      error:error
                         ok:!error || [error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue]];
  });
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
  if (!self.isRecording) return NSTerminateNow;
  // Finish writing the movie first, or the file is left without its index; the
  // finish callback quits again. (NSTerminateLater would deadlock: AppKit spins a
  // private run loop mode in which the main-queue callback never runs.)
  self.quitAfterRecording = YES;
  if (self.writer)
    [self finishWriter];
  else
    [self.movieOutput stopRecording];
  return NSTerminateCancel;
}

#pragma mark Plugins

- (void)startPlugins {
  NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pocket-viewer.sock"];
  self.plugins = [[PluginServer alloc] initWithSocketPath:path delegate:self];
  NSError *err;
  if (![self.plugins start:&err]) {
    NSLog(@"plugin socket %@ unavailable: %@", path, err.localizedDescription);
    self.plugins = nil;
    return;
  }
  NSLog(@"plugin socket: %@", path);
  for (NSString *cmd in optPlugins) [self.plugins launch:cmd];
  // Gimbal state for plugins that asked for it (e.g. to close a tracking loop).
  [NSTimer scheduledTimerWithTimeInterval:0.2
                                  repeats:YES
                                    block:^(NSTimer *t) {
    [self.plugins broadcastState:self.pluginState];
  }];
}

- (NSDictionary *)pluginState {
  NSMutableDictionary *st = [self.view.gimbalState mutableCopy];
  st[@"video"] = @{@"width" : @(self.size.width), @"height" : @(self.size.height), @"fps" : @(self.fps)};
  st[@"recording"] = @(self.isRecording);
  if (self.stackchan) st[@"fov"] = @[ @(kStackChanHorizontalFOV), @(kStackChanVerticalFOV) ];
  return st;
}

- (NSDictionary *)pluginHelloInfo {
  return self.pluginState;
}

- (void)pluginClient:(PluginClient *)client sent:(NSDictionary *)msg {
  NSString *type = msg[@"type"];
  NSString *layer = [msg[@"layer"] isKindOfClass:NSString.class] ? msg[@"layer"] : @"default";
  NSString *prefix = [NSString stringWithFormat:@"%d/", client.clientID];
  if ([type isEqual:@"draw"]) {
    NSArray *items = [msg[@"items"] isKindOfClass:NSArray.class] ? msg[@"items"] : @[];
    [self.view.overlay setItems:items forKey:[prefix stringByAppendingString:layer] ttl:num(msg, @"ttl", 0)];
  } else if ([type isEqual:@"clear"]) {
    BOOL oneLayer = [msg[@"layer"] isKindOfClass:NSString.class];
    [self.view.overlay removeKeysWithPrefix:oneLayer ? [prefix stringByAppendingString:layer] : prefix];
  } else if ([type isEqual:@"gimbal"] || [type isEqual:@"zoom"] || [type isEqual:@"roll"] ||
             [type isEqual:@"center"]) {
    [self.view handlePluginCommand:msg];
  } else if ([type isEqual:@"hud"]) {
    NSString *key = [msg[@"key"] isKindOfClass:NSString.class] ? msg[@"key"] : @"default";
    NSString *text = [msg[@"text"] isKindOfClass:NSString.class] ? msg[@"text"] : @"";
    [self.view setHudText:text
                    color:colorFromHex(msg[@"color"], NSColor.whiteColor)
                   forKey:[prefix stringByAppendingString:key]
                      ttl:num(msg, @"ttl", 0)];
  } else if ([type isEqual:@"record"]) {
    NSString *action = msg[@"action"];
    BOOL start = [action isEqual:@"start"], stop = [action isEqual:@"stop"];
    if ([action isEqual:@"toggle"] || (start && !self.isRecording) || (stop && self.isRecording))
      [self toggleRecording:nil];
  } else if ([type isEqual:@"snapshot"]) {
    self.snapshotPending = YES;  // the next video frame is saved
  } else if ([type isEqual:@"options"]) {
    [self plugin:client declaredOptions:msg[@"items"]];
  } else if ([type isEqual:@"log"]) {
    NSLog(@"[%@] %@", client.name, msg[@"text"]);
  } else {
    NSLog(@"[%@] unknown message type %@", client.name, type);
  }
}

- (void)pluginClientsChanged {
  NSMutableSet *ids = [NSMutableSet set];
  for (PluginClient *c in self.plugins.clients) [ids addObject:@(c.clientID)];
  [self.view.overlay keepClients:ids];
  [self.view keepHudClients:ids];
}

- (void)fillPluginsMenu:(NSMenu *)menu {
  [menu addItemWithTitle:@"Load Plugin…" action:@selector(loadPlugin:) keyEquivalent:@""].target = self;
  [menu addItem:NSMenuItem.separatorItem];
  NSArray *clients = self.plugins.clients, *pending = self.plugins.pendingTasks;
  for (PluginClient *c in clients) {
    NSString *stopTitle = [NSString stringWithFormat:@"Stop “%@”%@", c.name, c.task ? @"" : @" (external)"];
    if (!c.options.count) {
      NSMenuItem *item = [menu addItemWithTitle:stopTitle action:@selector(stopPlugin:) keyEquivalent:@""];
      item.target = self;
      item.representedObject = c;
      continue;
    }
    // A plugin with settings gets its own submenu: settings, then Stop.
    NSMenu *sub = [self addSubmenu:c.name to:menu];
    [self fillOptions:c.options of:c into:sub];
    [sub addItem:NSMenuItem.separatorItem];
    NSMenuItem *stop = [sub addItemWithTitle:stopTitle action:@selector(stopPlugin:) keyEquivalent:@""];
    stop.target = self;
    stop.representedObject = c;
  }
  for (NSTask *t in pending) {
    NSMenuItem *item = [menu addItemWithTitle:[NSString stringWithFormat:@"Stop “%@” (starting)",
                                                                       [self.plugins nameOfTask:t]]
                                       action:@selector(stopPlugin:)
                                keyEquivalent:@""];
    item.target = self;
    item.representedObject = t;
  }
  if (!clients.count && !pending.count) [menu addItemWithTitle:@"No plugins running" action:nil keyEquivalent:@""];
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItemWithTitle:self.plugins ? [@"Socket: " stringByAppendingString:self.plugins.socketPath]
                                      : @"Plugin socket unavailable"
                  action:nil
           keyEquivalent:@""];
}

static NSString *shellQuote(NSString *s) {
  return [NSString stringWithFormat:@"'%@'", [s stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

- (void)loadPlugin:(id)sender {
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  panel.message = @"Choose a plugin: an executable, or a .py / .sh / .ts / .js script";
  panel.prompt = @"Load";
  [panel beginSheetModalForWindow:self.window
                completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK) return;
    NSString *path = panel.URL.path;
    NSString *ext = path.pathExtension.lowercaseString;
    BOOL node = [@[ @"ts", @"js", @"mjs" ] containsObject:ext];  // Node 22.18+ runs TypeScript as is
    NSString *cmd = [ext isEqual:@"py"]   ? [@"python3 " stringByAppendingString:shellQuote(path)]
                    : [ext isEqual:@"sh"] ? [@"/bin/sh " stringByAppendingString:shellQuote(path)]
                    : node                ? [@"node " stringByAppendingString:shellQuote(path)]
                                          : shellQuote(path);
    [self.plugins launch:cmd];
  }];
}

#pragma mark Plugin settings

// Keeps only well-formed items: {key, title, type: bool} or
// {key, title, type: choice, choices: [[value, label], ...]}, plus a value.
static NSArray<NSDictionary *> *validOptions(id items) {
  if (![items isKindOfClass:NSArray.class]) return @[];
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *o in items) {
    if (![o isKindOfClass:NSDictionary.class] || ![o[@"key"] isKindOfClass:NSString.class] ||
        ![o[@"title"] isKindOfClass:NSString.class])
      continue;
    if ([o[@"type"] isEqual:@"bool"]) {
      [out addObject:@{@"key" : o[@"key"], @"title" : o[@"title"], @"type" : @"bool",
                       @"value" : @([o[@"value"] isKindOfClass:NSNumber.class] && [o[@"value"] boolValue])}];
    } else if ([o[@"type"] isEqual:@"choice"] && [o[@"choices"] isKindOfClass:NSArray.class]) {
      NSMutableArray *choices = [NSMutableArray array];
      for (NSArray *c in o[@"choices"])
        if ([c isKindOfClass:NSArray.class] && c.count == 2 && [c[1] isKindOfClass:NSString.class] &&
            ([c[0] isKindOfClass:NSString.class] || [c[0] isKindOfClass:NSNumber.class]))
          [choices addObject:c];
      if (choices.count)
        [out addObject:@{@"key" : o[@"key"], @"title" : o[@"title"], @"type" : @"choice", @"choices" : choices,
                         @"value" : o[@"value"] ?: NSNull.null}];
    }
  }
  return out;
}

- (NSMutableDictionary *)savedSettingsFor:(NSString *)plugin {
  NSDictionary *all = [NSUserDefaults.standardUserDefaults dictionaryForKey:kDefaultsPluginSettings];
  return [all[plugin] isKindOfClass:NSDictionary.class] ? [all[plugin] mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)plugin:(PluginClient *)client declaredOptions:(id)items {
  NSArray *options = validOptions(items);
  // Restore what the user chose last time, if the plugin reports otherwise.
  // Only on its first declaration: later ones echo changes still in flight.
  BOOL first = client.options == nil;
  NSDictionary *saved = first ? [self savedSettingsFor:client.name] : @{};
  NSMutableArray *restored = [NSMutableArray array];
  for (NSDictionary *o in options) {
    id want = saved[o[@"key"]];
    // Saved values must still fit: plugins change their choices over time.
    BOOL fits = [o[@"type"] isEqual:@"bool"] && [want isKindOfClass:NSNumber.class];
    for (NSArray *c in o[@"choices"]) fits = fits || [c[0] isEqual:want];
    if (want && fits && ![want isEqual:o[@"value"]]) {
      [self.plugins send:@{@"type" : @"set", @"key" : o[@"key"], @"value" : want} to:client];
      NSMutableDictionary *m = [o mutableCopy];
      m[@"value"] = want;
      [restored addObject:m];
    } else {
      [restored addObject:o];
    }
  }
  client.options = restored;
}

- (void)fillOptions:(NSArray<NSDictionary *> *)options of:(PluginClient *)client into:(NSMenu *)menu {
  for (NSDictionary *o in options) {
    if ([o[@"type"] isEqual:@"bool"]) {
      NSMenuItem *item = [menu addItemWithTitle:o[@"title"] action:@selector(setPluginOption:) keyEquivalent:@""];
      item.target = self;
      item.state = [o[@"value"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
      item.representedObject = @{@"client" : client, @"key" : o[@"key"], @"value" : @(![o[@"value"] boolValue])};
      continue;
    }
    NSString *current = @"";
    for (NSArray *c in o[@"choices"])
      if ([c[0] isEqual:o[@"value"]]) current = c[1];
    NSMenu *sub = [self addSubmenu:[NSString stringWithFormat:@"%@: %@", o[@"title"], current] to:menu];
    for (NSArray *c in o[@"choices"]) {
      NSMenuItem *item = [sub addItemWithTitle:c[1] action:@selector(setPluginOption:) keyEquivalent:@""];
      item.target = self;
      item.state = [c[0] isEqual:o[@"value"]] ? NSControlStateValueOn : NSControlStateValueOff;
      item.representedObject = @{@"client" : client, @"key" : o[@"key"], @"value" : c[0]};
    }
  }
}

- (void)setPluginOption:(NSMenuItem *)item {
  PluginClient *client = item.representedObject[@"client"];
  NSString *key = item.representedObject[@"key"];
  id value = item.representedObject[@"value"];
  [self.plugins send:@{@"type" : @"set", @"key" : key, @"value" : value} to:client];
  NSMutableArray *options = [NSMutableArray array];
  for (NSDictionary *o in client.options) {
    NSMutableDictionary *m = [o mutableCopy];
    if ([o[@"key"] isEqual:key]) m[@"value"] = value;
    [options addObject:m];
  }
  client.options = options;
  NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kDefaultsPluginSettings] mutableCopy]
                                 ?: [NSMutableDictionary dictionary];
  NSMutableDictionary *mine = [self savedSettingsFor:client.name];
  mine[key] = value;
  all[client.name] = mine;
  [NSUserDefaults.standardUserDefaults setObject:all forKey:kDefaultsPluginSettings];
}

- (void)stopPlugin:(NSMenuItem *)item {
  id target = item.representedObject;
  if ([target isKindOfClass:PluginClient.class])
    [self.plugins stopClient:target];
  else
    [self.plugins stopTask:target];
}

- (void)applicationWillTerminate:(NSNotification *)note {
  [self.plugins shutdown];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {
  return YES;
}
@end

static void listFormats(void) {
  AVCaptureDevice *video = findCamera();
  if (!video) {
    fprintf(stderr, "%s camera not found\n", kDeviceName.UTF8String);
    exit(1);
  }
  for (NSValue *v in availableSizes(video)) {
    CMVideoDimensions s;
    [v getValue:&s];
    NSMutableArray *rates = [NSMutableArray array];
    for (NSNumber *r in availableFrameRates(video, s)) [rates addObject:fpsString(r.doubleValue)];
    printf("%-10s %s fps\n", [NSString stringWithFormat:@"%dx%d", s.width, s.height].UTF8String,
           [rates componentsJoinedByString:@", "].UTF8String);
  }
  printf("\naudio inputs (-a):\n");
  for (AVCaptureDevice *d in audioDevices()) printf("  %s\n", d.localizedName.UTF8String);
  printf("\nmonitor outputs (Audio Output menu):\n");
  for (NSArray<NSString *> *o in outputDevices()) printf("  %s\n", o[1].UTF8String);
}

int main(int argc, char **argv) {
  @autoreleasepool {
    int opt;
    while ((opt = getopt(argc, argv, "d:s:r:a:o:c:t:p:elh")) != -1) {
      switch (opt) {
        case 'd': optDevice = @(optarg); break;
        case 's': optSize = @(optarg); break;
        case 'r': optFps = @(optarg); break;
        case 'o': optOutDir = @(optarg); break;
        case 'a': optAudio = @(optarg); break;
        case 't': optRecordSecs = atof(optarg); break;
        case 'c': optCodec = @(optarg); break;
        case 'e': optEchoCancel = YES; break;
        case 'p':
          if (!optPlugins) optPlugins = [NSMutableArray array];
          [optPlugins addObject:@(optarg)];
          break;
        case 'l': listFormats(); return 0;
        default:
          fprintf(stderr, "usage: pocket-viewer [-d stackchan[:PORT]] [-s WxH] [-r fps] [-a audio] [-o dir] [-c codec] [-e] "
                          "[-p cmd]... [-t secs] [-l]\n");
          return 2;
      }
    }
    if (optDevice && ![optDevice isEqual:@"stackchan"] && ![optDevice hasPrefix:@"stackchan:"]) {
      fprintf(stderr, "unknown device %s (use stackchan or stackchan:/dev/cu.…)\n", optDevice.UTF8String);
      return 2;
    }
    if (optDevice && !stackChanPort()) {
      fprintf(stderr, "no StackChan on USB (is it plugged in and running stackchan-cam?)\n");
      return 1;
    }
    if (stackChanPort()) stackchan_use_as_gimbal(stackChanPort());
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;
    AppDelegate *delegate = [AppDelegate new];
    app.delegate = delegate;
    [app run];
  }
  return 0;
}
