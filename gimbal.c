// The Pocket 3 exposes standard UVC Camera Terminal controls:
//   PanTilt Absolute (selector 0x0D), Zoom Absolute (0x0B), Roll Absolute (0x0F).
// Pan/tilt are in arc-seconds (3600 = 1 degree); roll is in whole degrees (-30..30). Requests go straight to the
// default control pipe via IOKit, so no root and no exclusive open is needed
// (libusb fails here because UVCAssistant owns the device).

#include "gimbal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdint.h>
#include <math.h>
#include <stdio.h>

#define VID 0x2ca3
#define PID 0x0023
#define CT_ENTITY 1  // Camera Terminal ID
#define VC_IFACE 0   // VideoControl interface

#define SEL_ZOOM 0x0B
#define SEL_PANTILT 0x0D
#define SEL_ROLL 0x0F

#define SET_CUR 0x01
#define GET_CUR 0x81
#define GET_MIN 0x82
#define GET_MAX 0x83

static IOUSBDeviceInterface **dev;
static gimbal_range rng;
static const gimbal_backend *backend;

void gimbal_set_backend(const gimbal_backend *b) { backend = b; }

static int ctrl(int request, int selector, void *data, int len) {
  IOUSBDevRequest r = {
      .bmRequestType = request == SET_CUR ? 0x21 : 0xA1,
      .bRequest = request,
      .wValue = selector << 8,
      .wIndex = (CT_ENTITY << 8) | VC_IFACE,
      .wLength = len,
      .pData = data,
  };
  IOReturn e = (*dev)->DeviceRequest(dev, &r);
  if (e != kIOReturnSuccess) {
    fprintf(stderr, "UVC request 0x%02x sel 0x%02x failed: 0x%x\n", request, selector, e);
    return -1;
  }
  return 0;
}

static double clamp(double x, double lo, double hi) { return x < lo ? lo : x > hi ? hi : x; }

static int pantilt(int request, double *pan, double *tilt) {
  int32_t v[2];
  if (ctrl(request, SEL_PANTILT, v, sizeof v)) return -1;
  *pan = v[0] / 3600.0;
  *tilt = v[1] / 3600.0;
  return 0;
}

static int zoom(int request, int *out) {
  uint16_t v;
  if (ctrl(request, SEL_ZOOM, &v, sizeof v)) return -1;
  *out = v;
  return 0;
}

int gimbal_open(gimbal_range *range) {
  if (backend) {
    if (backend->open(&rng)) return -1;
    if (range) *range = rng;
    return 0;
  }
  CFMutableDictionaryRef m = IOServiceMatching(kIOUSBDeviceClassName);
  int vid = VID, pid = PID;
  CFDictionarySetValue(m, CFSTR(kUSBVendorID), CFNumberCreate(NULL, kCFNumberIntType, &vid));
  CFDictionarySetValue(m, CFSTR(kUSBProductID), CFNumberCreate(NULL, kCFNumberIntType, &pid));
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, m);
  if (!svc) {
    fprintf(stderr, "DJI Pocket 3 not found (is it in webcam mode?)\n");
    return -1;
  }
  IOCFPlugInInterface **plugin;
  SInt32 score;
  kern_return_t kr = IOCreatePlugInInterfaceForService(svc, kIOUSBDeviceUserClientTypeID,
                                                       kIOCFPlugInInterfaceID, &plugin, &score);
  IOObjectRelease(svc);
  if (kr != KERN_SUCCESS || !plugin) {
    fprintf(stderr, "IOCreatePlugInInterfaceForService failed: 0x%x\n", kr);
    return -1;
  }
  (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID), (LPVOID *)&dev);
  (*plugin)->Release(plugin);
  if (!dev) return -1;

  if (pantilt(GET_MIN, &rng.pan_min, &rng.tilt_min) ||
      pantilt(GET_MAX, &rng.pan_max, &rng.tilt_max) || zoom(GET_MIN, &rng.zoom_min) ||
      zoom(GET_MAX, &rng.zoom_max))
    return -1;
  if (range) *range = rng;
  return 0;
}

int gimbal_get(double *pan, double *tilt) {
  return backend ? backend->get(pan, tilt) : pantilt(GET_CUR, pan, tilt);
}

int gimbal_set(double pan, double tilt) {
  if (backend) return backend->set(clamp(pan, rng.pan_min, rng.pan_max), clamp(tilt, rng.tilt_min, rng.tilt_max));
  int32_t v[2] = {(int32_t)(clamp(pan, rng.pan_min, rng.pan_max) * 3600),
                  (int32_t)(clamp(tilt, rng.tilt_min, rng.tilt_max) * 3600)};
  return ctrl(SET_CUR, SEL_PANTILT, v, sizeof v);
}

int gimbal_get_zoom(int *z) {
  if (backend) {
    *z = 100;
    return 0;
  }
  return zoom(GET_CUR, z);
}

int gimbal_set_zoom(int z) {
  if (backend) return 0;
  uint16_t v = (uint16_t)clamp(z, rng.zoom_min, rng.zoom_max);
  return ctrl(SET_CUR, SEL_ZOOM, &v, sizeof v);
}

int gimbal_get_roll(double *roll) {
  if (backend) {
    *roll = 0;
    return 0;
  }
  int16_t v;
  if (ctrl(GET_CUR, SEL_ROLL, &v, sizeof v)) return -1;
  *roll = v;
  return 0;
}

int gimbal_set_roll(double roll) {
  if (backend) return 0;
  int16_t v = (int16_t)lround(clamp(roll, -30, 30));
  return ctrl(SET_CUR, SEL_ROLL, &v, sizeof v);
}
