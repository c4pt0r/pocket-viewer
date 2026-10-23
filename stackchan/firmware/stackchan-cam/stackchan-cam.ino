// stackchan-cam — firmware for M5Stack StackChan (CoreS3 head) that streams the
// GC0308 camera and takes pan/tilt commands over the USB cable, so
// pocket-viewer can use the robot as its camera and gimbal (-d stackchan).
//
// The robot appears on the Mac as a serial port (TinyUSB CDC). Up, packets:
//   "SCF1" type:u8 length:u32le payload
//     'J'  a JPEG frame
//     'S'  head state, JSON: {"yaw","pitch","moving","yawRange","pitchRange",
//          "width","height","fps","camera","version"}, every 0.2 s
// Down, text lines:
//   stream                  start or keep streaming; re-send at least every 3 s
//   move YAW PITCH [SPEED]  absolute degrees: yaw −128…128, + turns the camera
//                           right; pitch 5…85, + up; speed 0…1000 (default 600)
//   home                    yaw 0, pitch 5
// Nothing is sent until the first "stream", so a serial monitor sees no binary.
//
// The camera has no JPEG encoder: one task encodes frames while another sends
// the newest one, so a slow link skips frames instead of falling behind.

#include <Arduino.h>
#include <M5StackChan.h>
#include <esp_camera.h>
#include <img_converters.h>

#include <algorithm>

static const char *kVersion = "stackchan-cam 1";
static const int kJpegQuality = 80;  // frame2jpg quality, 1…100
static const int kDefaultSpeed = 600;
static const int kPitchMin = 50, kPitchMax = 850;  // tenths of a degree; M5Stack advises 5°…85°
static const int kYawLimit = 1280;

// ---------------------------------------------------------------- camera

static camera_config_t camera_config = {
    .pin_pwdn = -1,
    .pin_reset = -1,
    .pin_xclk = -1,
    .pin_sccb_sda = 12,
    .pin_sccb_scl = 11,
    .pin_d7 = 47,
    .pin_d6 = 48,
    .pin_d5 = 16,
    .pin_d4 = 15,
    .pin_d3 = 42,
    .pin_d2 = 41,
    .pin_d1 = 40,
    .pin_d0 = 39,
    .pin_vsync = 46,
    .pin_href = 38,
    .pin_pclk = 45,
    .xclk_freq_hz = 20000000,
    .ledc_timer = LEDC_TIMER_0,
    .ledc_channel = LEDC_CHANNEL_0,
    .pixel_format = PIXFORMAT_RGB565,  // the GC0308 cannot encode JPEG itself
    .frame_size = FRAMESIZE_QVGA,
    .jpeg_quality = 0,
    .fb_count = 2,
    .fb_location = CAMERA_FB_IN_PSRAM,
    .grab_mode = CAMERA_GRAB_LATEST,  // lowest latency: always the newest frame
    .sccb_i2c_port = 0,
};

static bool camera_ok;
static int frame_width, frame_height;
static volatile float measured_fps;
static volatile bool streaming;  // the Mac asked for frames within the last 3 s

// The newest encoded frame, handed from the encoder to the USB task.
static SemaphoreHandle_t jpeg_lock;
static uint8_t *jpeg_buf;  // PSRAM, owned under jpeg_lock
static size_t jpeg_len, jpeg_cap;
static volatile uint32_t jpeg_seq;

// The camera's SCCB bus shares GPIO 11/12 with M5Unified's internal I2C (touch,
// power, the body's IO expander). Give the pins to the camera driver for its
// one-time setup, then hand them back to M5Unified.
static bool init_camera() {
  i2c_port_t port = M5.In_I2C.getPort();
  int sda = M5.In_I2C.getSDA(), scl = M5.In_I2C.getSCL();
  camera_config.sccb_i2c_port = port == I2C_NUM_0 ? 1 : 0;
  M5.In_I2C.release();
  esp_err_t err = esp_camera_init(&camera_config);
  M5.In_I2C.begin(port, sda, scl);
  return err == ESP_OK;
}

static void encoder_task(void *) {
  uint32_t frames = 0, window_start = millis();
  for (;;) {
    if (!streaming) {
      measured_fps = 0;
      vTaskDelay(pdMS_TO_TICKS(50));
      continue;
    }
    camera_fb_t *fb = esp_camera_fb_get();
    if (!fb) {
      vTaskDelay(pdMS_TO_TICKS(10));
      continue;
    }
    frame_width = fb->width;
    frame_height = fb->height;
    uint8_t *out = nullptr;
    size_t out_len = 0;
    bool ok = frame2jpg(fb, kJpegQuality, &out, &out_len);
    esp_camera_fb_return(fb);
    if (!ok) continue;

    xSemaphoreTake(jpeg_lock, portMAX_DELAY);
    if (out_len > jpeg_cap) {
      free(jpeg_buf);
      jpeg_cap = out_len + out_len / 2;
      jpeg_buf = (uint8_t *)heap_caps_malloc(jpeg_cap, MALLOC_CAP_SPIRAM);
    }
    if (jpeg_buf) {
      memcpy(jpeg_buf, out, out_len);
      jpeg_len = out_len;
      jpeg_seq = jpeg_seq + 1;
    }
    xSemaphoreGive(jpeg_lock);
    free(out);

    frames++;
    uint32_t now = millis();
    if (now - window_start >= 1000) {
      measured_fps = frames * 1000.0f / (now - window_start);
      frames = 0;
      window_start = now;
    }
  }
}

// Copies the newest JPEG, if it is newer than *seq, into *buf (grown as
// needed). Returns its length, or 0 if there is no newer frame yet.
static size_t take_jpeg(uint32_t *seq, uint8_t **buf, size_t *cap) {
  if (jpeg_seq == *seq) return 0;
  xSemaphoreTake(jpeg_lock, portMAX_DELAY);
  size_t len = jpeg_len;
  if (len > *cap) {
    free(*buf);
    *cap = len + len / 2;
    *buf = (uint8_t *)heap_caps_malloc(*cap, MALLOC_CAP_SPIRAM);
  }
  if (*buf && len) memcpy(*buf, jpeg_buf, len);
  *seq = jpeg_seq;
  xSemaphoreGive(jpeg_lock);
  return *buf ? len : 0;
}

// ---------------------------------------------------------------- head

static void format_state(char *json, size_t size) {
  auto angles = M5StackChan.Motion.getCurrentAngles();
  bool moving = M5StackChan.Motion.isMoving();
  snprintf(json, size,
           "{\"yaw\":%.1f,\"pitch\":%.1f,\"moving\":%s,\"yawRange\":[%d,%d],\"pitchRange\":[%d,%d],"
           "\"width\":%d,\"height\":%d,\"fps\":%.1f,\"camera\":%s,\"version\":\"%s\"}",
           angles.x / 10.0, angles.y / 10.0, moving ? "true" : "false", -kYawLimit / 10, kYawLimit / 10,
           kPitchMin / 10, kPitchMax / 10, frame_width, frame_height, measured_fps,
           camera_ok ? "true" : "false", kVersion);
}

// "move YAW PITCH [SPEED]" or "home". Yaw + turns the camera right: M5Stack's
// examples call it "left", as seen from in front of the robot.
static void run_command(char *line) {
  char *cmd = strtok(line, " \t\r");
  if (!cmd) return;
  if (!strcmp(cmd, "move")) {
    char *yaw = strtok(nullptr, " \t\r"), *pitch = strtok(nullptr, " \t\r"), *speed = strtok(nullptr, " \t\r");
    if (!yaw || !pitch) return;
    M5StackChan.Motion.move(constrain((int)lroundf(atof(yaw) * 10), -kYawLimit, kYawLimit),
                            constrain((int)lroundf(atof(pitch) * 10), kPitchMin, kPitchMax),
                            speed ? constrain(atoi(speed), 0, 1000) : kDefaultSpeed);
  } else if (!strcmp(cmd, "home")) {
    M5StackChan.Motion.move(0, kPitchMin, kDefaultSpeed);
  }
}

// ---------------------------------------------------------------- USB

// One packet; false if the Mac stopped reading (the write timed out).
static bool send_packet(char type, const void *data, size_t len) {
  uint8_t head[9] = {'S', 'C', 'F', '1', (uint8_t)type, (uint8_t)len, (uint8_t)(len >> 8), (uint8_t)(len >> 16),
                     (uint8_t)(len >> 24)};
  return Serial.write(head, sizeof head) == sizeof head && Serial.write((const uint8_t *)data, len) == len;
}

// The only task that touches USB: commands in, frames and state out.
static void usb_task(void *) {
  char line[96];
  size_t line_len = 0;
  uint8_t *buf = nullptr;
  size_t cap = 0;
  uint32_t seq = 0, last_stream_cmd = 0, last_state = 0;
  for (;;) {
    uint8_t in[64];
    int n = Serial.read(in, std::min<int>(Serial.available(), sizeof in));
    if (n <= 0 && !streaming) vTaskDelay(pdMS_TO_TICKS(20));
    for (int i = 0; i < n; i++) {
      if (in[i] != '\n') {
        if (line_len < sizeof line - 1) line[line_len++] = in[i];
        continue;
      }
      line[line_len] = 0;
      line_len = 0;
      if (!strncmp(line, "stream", 6)) {
        last_stream_cmd = millis();
        streaming = true;
      } else {
        run_command(line);
      }
    }
    if (!streaming) continue;

    bool ok = true;
    if (millis() - last_state >= 200) {
      last_state = millis();
      char json[256];
      format_state(json, sizeof json);
      ok = send_packet('S', json, strlen(json));
    }
    size_t len = ok ? take_jpeg(&seq, &buf, &cap) : 0;
    if (len)
      ok = send_packet('J', buf, len);
    else if (ok)
      vTaskDelay(pdMS_TO_TICKS(2));
    if (!ok || millis() - last_stream_cmd > 3000) streaming = false;  // Mac gone: wait until it asks again
  }
}

// ---------------------------------------------------------------- display

static void show_status() {
  static int shown = -1;
  if (shown == streaming) return;
  shown = streaming;
  auto &d = M5StackChan.Display();
  d.fillScreen(TFT_BLACK);
  d.setTextDatum(middle_center);
  d.setFont(&fonts::FreeSansBold12pt7b);
  d.setTextColor(camera_ok ? TFT_GREENYELLOW : TFT_RED);
  d.drawString(camera_ok ? "stackchan-cam" : "camera failed", d.width() / 2, d.height() / 2 - 16);
  d.setFont(&fonts::FreeSans9pt7b);
  d.setTextColor(streaming ? TFT_WHITE : TFT_LIGHTGREY);
  d.drawString(streaming ? "streaming to the Mac" : "waiting for the Mac (USB)", d.width() / 2, d.height() / 2 + 18);
}

// ---------------------------------------------------------------- main

void setup() {
  esp_log_level_set("*", ESP_LOG_NONE);  // logs would share the USB port with the video
  Serial.setTxTimeoutMs(200);
  M5StackChan.begin();
  M5StackChan.Display().setBrightness(80);
  jpeg_lock = xSemaphoreCreateMutex();
  camera_ok = init_camera();
  if (camera_ok) xTaskCreatePinnedToCore(encoder_task, "encoder", 6144, nullptr, 4, nullptr, 1);
  xTaskCreatePinnedToCore(usb_task, "usb", 6144, nullptr, 5, nullptr, 0);
  M5StackChan.Motion.move(0, kPitchMin, 300);
  show_status();
}

void loop() {
  M5StackChan.update();
  show_status();
  delay(50);
}
