// gimbal — DJI Osmo Pocket 3 gimbal control over standard UVC Camera Terminal
// controls (PanTilt/Zoom/Roll Absolute), sent via IOKit on macOS.
#pragma once

typedef struct {
  double pan_min, pan_max, tilt_min, tilt_max;  // degrees
  int zoom_min, zoom_max;
} gimbal_range;

// Opens the device and reads ranges into *range. Returns 0 on success.
int gimbal_open(gimbal_range *range);
int gimbal_get(double *pan, double *tilt);           // degrees
int gimbal_set(double pan, double tilt);             // degrees, clamped to range
int gimbal_get_zoom(int *zoom);
int gimbal_set_zoom(int zoom);                       // clamped to range
int gimbal_get_roll(double *roll);                   // degrees
int gimbal_set_roll(double roll);

// Another pan/tilt head (e.g. StackChan, see stackchan.h) can stand in for the
// Pocket 3: once set, the calls above go to it. It has no zoom or roll; those
// read back as 100 and 0 and ignore writes. Call before gimbal_open.
typedef struct {
  int (*open)(gimbal_range *range);
  int (*get)(double *pan, double *tilt);
  int (*set)(double pan, double tilt);  // already clamped to range
} gimbal_backend;
void gimbal_set_backend(const gimbal_backend *backend);
