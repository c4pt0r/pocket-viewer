// stackchan — the M5Stack StackChan robot as pocket-viewer's camera and gimbal.
//
// The robot runs stackchan/firmware/stackchan-cam and is plugged in over USB,
// where it shows up as a serial port. It sends JPEG frames and its head angles
// up, and takes move commands down. Here the frames become host-clock
// CMSampleBuffers, like the Pocket 3's capture output, and the head (yaw/pitch
// servos) becomes a gimbal_* backend: +pan turns right, +tilt up.
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

// Field of view of the StackChan camera (GC0308 behind the CoreS3 lens), degrees.
extern const double kStackChanHorizontalFOV, kStackChanVerticalFOV;

// The serial port of a StackChan on USB (an Espressif device), or nil.
NSString *_Nullable stackchan_usb_port(void);

@interface StackChanCamera : NSObject

- (instancetype)initWithPort:(NSString *)port;  // e.g. /dev/cu.usbmodem…
// Frames arrive on a private serial queue as BGRA buffers stamped on the host
// clock at receipt. Survives the robot being unplugged and plugged back in.
- (void)startWithHandler:(void (^)(CMSampleBufferRef frame))handler;

@end

// Routes every gimbal_* call to the robot on port. Call before gimbal_open.
void stackchan_use_as_gimbal(NSString *port);

NS_ASSUME_NONNULL_END
