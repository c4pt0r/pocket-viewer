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
