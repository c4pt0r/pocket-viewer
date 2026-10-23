#import "stackchan.h"

#import <ImageIO/ImageIO.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/serial/IOSerialKeys.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

#include "gimbal.h"

// Measured against a static ceiling: tilting 10° moved it 77.5 of 240 px, so
// 31° tall; the width follows from the 4:3 sensor. Plugins get it as state.fov.
const double kStackChanHorizontalFOV = 41, kStackChanVerticalFOV = 31;

NSString *stackchan_usb_port(void) {
  // The robot enumerates as an Espressif device (VID 0x303a); find its serial port.
  io_iterator_t it;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &it)) return nil;
  NSString *found = nil;
  io_object_t svc;
  while (!found && (svc = IOIteratorNext(it))) {
    NSNumber *vid = CFBridgingRelease(IORegistryEntrySearchCFProperty(
        svc, kIOServicePlane, CFSTR("idVendor"), NULL, kIORegistryIterateRecursively | kIORegistryIterateParents));
    NSString *path = CFBridgingRelease(IORegistryEntryCreateCFProperty(svc, CFSTR(kIOCalloutDeviceKey), NULL, 0));
    if ([vid isKindOfClass:NSNumber.class] && vid.intValue == 0x303a && path) found = path;
    IOObjectRelease(svc);
  }
  IOObjectRelease(it);
  return found;
}

// Offset of bytes in data at or after from, or NSNotFound.
static NSUInteger find(NSData *data, const char *bytes, NSUInteger from) {
  NSData *needle = [NSData dataWithBytesNoCopy:(void *)bytes length:strlen(bytes) freeWhenDone:NO];
  return [data rangeOfData:needle options:0 range:NSMakeRange(from, data.length - from)].location;
}

// Decodes a JPEG into a BGRA pixel buffer (IOSurface-backed, so the display
// layer and the movie writer take it without copying).
static CVPixelBufferRef createPixelBuffer(NSData *jpeg) {
  CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpeg, NULL);
  if (!src) return NULL;
  CGImageRef image = CGImageSourceCreateImageAtIndex(src, 0, NULL);
  CFRelease(src);
  if (!image) return NULL;
  size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
  CVPixelBufferRef pb = NULL;
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
  if (CVPixelBufferCreate(NULL, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pb)) {
    CGImageRelease(image);
    return NULL;
  }
  CVPixelBufferLockBaseAddress(pb, 0);
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8, CVPixelBufferGetBytesPerRow(pb),
                                           srgb, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
  CGContextRelease(ctx);
  CGColorSpaceRelease(srgb);
  CVPixelBufferUnlockBaseAddress(pb, 0);
  CGImageRelease(image);
  return pb;
}

static CMSampleBufferRef createSampleBuffer(CVPixelBufferRef pb, CMTime pts) {
  CMVideoFormatDescriptionRef format = NULL;
  if (CMVideoFormatDescriptionCreateForImageBuffer(NULL, pb, &format)) return NULL;
  CMSampleTimingInfo timing = {.duration = kCMTimeInvalid, .presentationTimeStamp = pts,
                               .decodeTimeStamp = kCMTimeInvalid};
  CMSampleBufferRef sb = NULL;
  CMSampleBufferCreateReadyWithImageBuffer(NULL, pb, format, &timing, &sb);
  CFRelease(format);
  if (!sb) return NULL;
  // Show on arrival: the display layer has no timebase to schedule against.
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
  CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0),
                       kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  return sb;
}

#pragma mark Link

// The serial connection, shared by the camera and the gimbal backend. Packets
// up are "SCF1", a type byte ('J' JPEG, 'S' state JSON), a little-endian u32
// length and the payload; commands down are text lines (see stackchan-cam.ino).
// The robot streams only while it keeps hearing "stream", so this sends it
// every second.
@interface StackChanLink : NSObject
+ (instancetype)linkForPort:(NSString *)port;
@property(atomic, copy, nullable) void (^onFrame)(NSData *jpeg);  // on the link's queue
@property(atomic, copy, nullable) NSDictionary *state;            // latest report; nil until the first
- (void)sendLine:(NSString *)line;
@end

@implementation StackChanLink {
  NSString *_port;
  dispatch_queue_t _queue;  // owns everything below
  int _fd;
  dispatch_source_t _reader, _keepalive;
  NSMutableData *_buffer;
  int _lastOpenError;
}

+ (instancetype)linkForPort:(NSString *)port {
  static NSMutableDictionary<NSString *, StackChanLink *> *links;
  @synchronized(self) {
    if (!links) links = [NSMutableDictionary dictionary];
    if (!links[port]) links[port] = [[StackChanLink alloc] initWithPort:port];
    return links[port];
  }
}

- (instancetype)initWithPort:(NSString *)port {
  if ((self = [super init])) {
    _port = [port copy];
    _queue = dispatch_queue_create("stackchan", DISPATCH_QUEUE_SERIAL);
    _fd = -1;
    _buffer = [NSMutableData data];
    dispatch_async(_queue, ^{
      [self open];
    });
  }
  return self;
}

- (void)open {
  int fd = open(_port.fileSystemRepresentation, O_RDWR | O_NOCTTY | O_NONBLOCK);
  if (fd < 0) {
    if (errno != _lastOpenError)  // say why once, not every second
      NSLog(@"StackChan: cannot open %@: %s%@", _port, strerror(errno),
            errno == EBUSY ? @" (another program, e.g. another pocket-viewer, has it open)" : @"");
    _lastOpenError = errno;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _queue, ^{
      [self open];  // unplugged or rebooting: keep trying
    });
    return;
  }
  ioctl(fd, TIOCEXCL);
  struct termios t;
  tcgetattr(fd, &t);
  cfmakeraw(&t);
  t.c_cflag |= CLOCAL | CREAD;
  tcsetattr(fd, TCSANOW, &t);
  // DTR on tells the robot's USB CDC someone is listening. RTS stays off: RTS
  // without DTR is half of the esptool sequence that reboots it into the bootloader.
  int dtr = TIOCM_DTR, rts = TIOCM_RTS;
  ioctl(fd, TIOCMBIS, &dtr);
  ioctl(fd, TIOCMBIC, &rts);
  _fd = fd;
  _lastOpenError = 0;
  _buffer.length = 0;
  NSLog(@"StackChan: connected on %@", _port);

  _reader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, _queue);
  dispatch_source_set_event_handler(_reader, ^{
    [self readAvailable];
  });
  dispatch_resume(_reader);
  _keepalive = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_keepalive, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(_keepalive, ^{
    [self write:@"stream\n"];
  });
  dispatch_resume(_keepalive);
}

- (void)closeAndRetry {
  if (_fd < 0) return;
  NSLog(@"StackChan: %@ disconnected, waiting for it", _port);
  dispatch_source_cancel(_reader);
  dispatch_source_cancel(_keepalive);
  _reader = _keepalive = nil;
  close(_fd);
  _fd = -1;
  self.state = nil;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), _queue, ^{
    [self open];
  });
}

- (void)write:(NSString *)line {
  if (_fd < 0) return;
  const char *bytes = line.UTF8String;
  if (write(_fd, bytes, strlen(bytes)) < 0 && errno != EAGAIN) [self closeAndRetry];
}

- (void)sendLine:(NSString *)line {
  dispatch_async(_queue, ^{
    [self write:[line stringByAppendingString:@"\n"]];
  });
}

- (void)readAvailable {
  uint8_t chunk[65536];
  ssize_t n = read(_fd, chunk, sizeof chunk);
  if (n <= 0) {
    if (n == 0 || errno != EAGAIN) [self closeAndRetry];
    return;
  }
  [_buffer appendBytes:chunk length:n];

  NSData *latestFrame = nil;
  NSUInteger pos = 0;
  for (;;) {
    NSUInteger at = find(_buffer, "SCF1", pos);
    if (at == NSNotFound) {  // keep a possible partial magic at the end
      pos = MAX(pos, _buffer.length > 3 ? _buffer.length - 3 : 0);
      break;
    }
    if (_buffer.length < at + 9) {
      pos = at;
      break;
    }
    const uint8_t *h = (const uint8_t *)_buffer.bytes + at;
    uint32_t length = h[5] | h[6] << 8 | h[7] << 16 | (uint32_t)h[8] << 24;
    if (length > 1 << 20) {  // not a real header: skip the magic and resync
      pos = at + 4;
      continue;
    }
    if (_buffer.length < at + 9 + length) {
      pos = at;
      break;
    }
    NSData *payload = [_buffer subdataWithRange:NSMakeRange(at + 9, length)];
    if (h[4] == 'J') {
      latestFrame = payload;  // several in one read: only the newest is worth decoding
    } else if (h[4] == 'S') {
      id obj = [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil];
      if ([obj isKindOfClass:NSDictionary.class]) self.state = obj;
    }
    pos = at + 9 + length;
  }
  if (pos) [_buffer replaceBytesInRange:NSMakeRange(0, pos) withBytes:NULL length:0];
  void (^onFrame)(NSData *) = self.onFrame;
  if (latestFrame && onFrame) onFrame(latestFrame);
}

@end

#pragma mark Camera

@implementation StackChanCamera {
  NSString *_port;
  NSUInteger _frames;  // link queue only
}

- (instancetype)initWithPort:(NSString *)port {
  if ((self = [super init])) _port = [port copy];
  return self;
}

- (void)startWithHandler:(void (^)(CMSampleBufferRef))handler {
  __weak StackChanCamera *weakSelf = self;
  [StackChanLink linkForPort:_port].onFrame = ^(NSData *jpeg) {
    StackChanCamera *camera = weakSelf;
    CMTime pts = CMClockGetTime(CMClockGetHostTimeClock());
    CVPixelBufferRef pb = createPixelBuffer(jpeg);
    if (!camera || !pb) return;
    CMSampleBufferRef sb = createSampleBuffer(pb, pts);
    if (sb && camera->_frames++ == 0)
      NSLog(@"StackChan: streaming %zux%zu", CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb));
    CVPixelBufferRelease(pb);
    if (!sb) return;
    handler(sb);
    CFRelease(sb);
  };
}

@end

#pragma mark Gimbal backend

// Yaw and pitch are pan and tilt as on the Pocket 3: + turns the camera right
// and up (measured against a static ceiling; M5Stack's examples call +yaw
// "left", as seen from in front). The state is whatever the robot last
// reported (every 0.2 s); moves are fire-and-forget lines.
static StackChanLink *gimbalLink;
static double targetPan = NAN, targetTilt = NAN;  // last move; gimbal queue only

static NSDictionary *headState(void) {
  for (int i = 0; i < 30 && !gimbalLink.state; i++) usleep(100000);  // the first report after connecting
  return gimbalLink.state;
}

static int sc_open(gimbal_range *range) {
  NSDictionary *st = headState();
  if (!st) {
    fprintf(stderr, "StackChan sent no head state within 3 s (is stackchan-cam running on it?)\n");
    return -1;
  }
  NSArray *yaw = st[@"yawRange"], *pitch = st[@"pitchRange"];
  range->pan_min = [yaw[0] doubleValue];
  range->pan_max = [yaw[1] doubleValue];
  range->tilt_min = [pitch[0] doubleValue];
  range->tilt_max = [pitch[1] doubleValue];
  range->zoom_min = range->zoom_max = 100;  // no zoom; 100 keeps plugins' FOV math at 1×
  return 0;
}

static int sc_get(double *pan, double *tilt) {
  NSDictionary *st = headState();
  if (!st) return -1;
  *pan = [st[@"yaw"] doubleValue];
  *tilt = [st[@"pitch"] doubleValue];
  // The servos stop 1–2° short of a target (their deadband). Once the head is
  // still, call that arrived, or closed loops that wait for the readback to
  // reach the target (Follow.swift) would wait forever.
  if (![st[@"moving"] boolValue] && fabs(*pan - targetPan) < 3 && fabs(*tilt - targetTilt) < 3) {
    *pan = targetPan;
    *tilt = targetTilt;
  }
  return 0;
}

static int sc_set(double pan, double tilt) {
  targetPan = pan;
  targetTilt = tilt;
  [gimbalLink sendLine:[NSString stringWithFormat:@"move %.1f %.1f", pan, tilt]];
  return 0;
}

void stackchan_use_as_gimbal(NSString *port) {
  gimbalLink = [StackChanLink linkForPort:port];
  static const gimbal_backend backend = {.open = sc_open, .get = sc_get, .set = sc_set};
  gimbal_set_backend(&backend);
}
