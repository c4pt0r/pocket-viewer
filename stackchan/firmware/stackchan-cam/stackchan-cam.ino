// stackchan-cam — firmware for M5Stack StackChan (CoreS3 head) that streams the
// GC0308 camera and takes pan/tilt commands over the USB cable, so
// pocket-viewer can use the robot as its camera and gimbal (-d stackchan).
//
// The robot appears on the Mac as a serial port (TinyUSB CDC). Up, packets:
//   "SCF1" type:u8 length:u32le payload
//     'J'  a JPEG frame
//     'S'  head state, JSON: {"yaw","pitch","moving","yawRange","pitchRange",
//          "width","height","fps","camera","screen","version"}, every 0.2 s
// Down, text lines:
//   stream                  start or keep streaming; re-send at least every 3 s
//   move YAW PITCH [SPEED]  absolute degrees: yaw −128…128, + turns the camera
//                           right; pitch 5…85, + up; speed 0…1000 (default 600)
//   home                    yaw 0, pitch 5
//   show LENGTH             LENGTH bytes of JPEG follow the newline, a picture
//                           for the screen ("screen": [width, height]; baseline
//                           JPEG, at most 64 KB). With none for 3 s, or after
//                           "show off", the screen goes back to the status.
//                           Send a newline before it: should the USB queue ever
//                           drop bytes, that is where reading gets back in step.
// Nothing is sent until the first "stream", so a serial monitor sees no binary.
//
// The camera has no JPEG encoder: one task encodes frames while another sends
// the newest one, so a slow link skips frames instead of falling behind.

#include <Arduino.h>
#include <M5StackChan.h>
#include <esp_camera.h>
#include <img_converters.h>

#include <algorithm>

static const char *kVersion = "stackchan-cam 2";
static const int kJpegQuality = 80;  // frame2jpg quality, 1…100
static const int kDefaultSpeed = 600;
static const int kPitchMin = 50, kPitchMax = 850;  // tenths of a degree; M5Stack advises 5°…85°
static const int kYawLimit = 1280;
static const size_t kMaxShow = 64 * 1024;  // largest picture "show" takes
static const uint32_t kShowTimeoutMs = 3000;

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

// ---------------------------------------------------------------- screen

// Pictures from the Mac pass through three buffers: the USB task fills one,
// the newest complete one waits in another, and loop() draws the third, so
// neither side waits for the other.
static SemaphoreHandle_t show_lock;
static uint8_t *show_buf[3];  // receiving, ready, drawing (PSRAM, kMaxShow each)
static size_t show_ready_len;
static volatile uint32_t show_seq;
static volatile uint32_t show_last_ms;  // when the last picture arrived
static volatile bool show_off;          // "show off": back to the status now
static int screen_width, screen_height;

// From the USB task: the receiving buffer holds a whole picture of len bytes.
static void picture_received(size_t len) {
  xSemaphoreTake(show_lock, portMAX_DELAY);
  std::swap(show_buf[0], show_buf[1]);
  show_ready_len = len;
  show_seq = show_seq + 1;
  show_last_ms = millis();
  show_off = false;
  xSemaphoreGive(show_lock);
}

// ---------------------------------------------------------------- head

static void format_state(char *json, size_t size) {
  auto angles = M5StackChan.Motion.getCurrentAngles();
  bool moving = M5StackChan.Motion.isMoving();
  snprintf(json, size,
           "{\"yaw\":%.1f,\"pitch\":%.1f,\"moving\":%s,\"yawRange\":[%d,%d],\"pitchRange\":[%d,%d],"
           "\"width\":%d,\"height\":%d,\"fps\":%.1f,\"camera\":%s,\"screen\":[%d,%d],\"version\":\"%s\"}",
           angles.x / 10.0, angles.y / 10.0, moving ? "true" : "false", -kYawLimit / 10, kYawLimit / 10,
           kPitchMin / 10, kPitchMax / 10, frame_width, frame_height, measured_fps,
           camera_ok ? "true" : "false", screen_width, screen_height, kVersion);
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
  } else if (!strcmp(cmd, "show")) {
    show_off = true;  // "show off"; "show LENGTH" is taken by usb_task
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
  static uint8_t in[4096];
  char line[96];
  size_t line_len = 0;
  uint8_t *buf = nullptr;
  size_t cap = 0;
  uint32_t seq = 0, last_stream_cmd = 0, last_state = 0;
  size_t picture_len = 0, picture_got = 0;  // a "show" picture coming in
  bool picture_keep = false;                // false: too big, skipped
  for (;;) {
    int n = Serial.read(in, std::min<int>(Serial.available(), sizeof in));
    if (n <= 0 && !streaming) vTaskDelay(pdMS_TO_TICKS(20));
    for (int i = 0; i < n; i++) {
      if (picture_got < picture_len) {
        size_t take = std::min<size_t>(picture_len - picture_got, n - i);
        if (picture_keep) memcpy(show_buf[0] + picture_got, in + i, take);
        picture_got += take;
        i += take - 1;
        if (picture_got == picture_len && picture_keep) picture_received(picture_len);
        continue;
      }
      if (in[i] != '\n') {
        if (line_len < sizeof line - 1) line[line_len++] = in[i];
        continue;
      }
      line[line_len] = 0;
      line_len = 0;
      if (!strncmp(line, "stream", 6)) {
        last_stream_cmd = millis();
        streaming = true;
      } else if (!strncmp(line, "show ", 5) && isdigit((unsigned char)line[5])) {
        picture_len = strtoul(line + 5, nullptr, 10);
        picture_got = 0;
        picture_keep = picture_len <= kMaxShow && show_buf[0];
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
    else if (ok && n <= 0)
      vTaskDelay(pdMS_TO_TICKS(2));
    if (!ok || millis() - last_stream_cmd > 3000) streaming = false;  // Mac gone: wait until it asks again
  }
}

// ---------------------------------------------------------------- display

static bool showing_picture;

static void show_status() {
  static int shown = -1;
  if (showing_picture) {
    // Back to the status once the pictures stop.
    if (!show_off && streaming && millis() - show_last_ms < kShowTimeoutMs) return;
    showing_picture = false;
    shown = -1;
  }
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

// Draws the newest picture from the Mac, if there is one.
static void show_picture() {
  static uint32_t drawn_seq;
  if (show_seq == drawn_seq || show_off) return;
  xSemaphoreTake(show_lock, portMAX_DELAY);
  std::swap(show_buf[1], show_buf[2]);
  size_t len = show_ready_len;
  drawn_seq = show_seq;
  xSemaphoreGive(show_lock);
  auto &d = M5StackChan.Display();
  if (!showing_picture) d.fillScreen(TFT_BLACK);
  showing_picture = true;
  d.drawJpg(show_buf[2], len, 0, 0, d.width(), d.height(), 0, 0, 0.0f, 0.0f, middle_center);
}

// ---------------------------------------------------------------- main

void setup() {
  esp_log_level_set("*", ESP_LOG_NONE);  // logs would share the USB port with the video
  Serial.setTxTimeoutMs(200);
  Serial.setRxBufferSize(16384);  // a picture arrives faster than 64-byte reads keep up with
  M5StackChan.begin();
  M5StackChan.Display().setBrightness(80);
  screen_width = M5StackChan.Display().width();
  screen_height = M5StackChan.Display().height();
  jpeg_lock = xSemaphoreCreateMutex();
  show_lock = xSemaphoreCreateMutex();
  for (auto &b : show_buf) b = (uint8_t *)heap_caps_malloc(kMaxShow, MALLOC_CAP_SPIRAM);
  if (!show_buf[0] || !show_buf[1] || !show_buf[2]) screen_width = screen_height = 0;
  camera_ok = init_camera();
  if (camera_ok) xTaskCreatePinnedToCore(encoder_task, "encoder", 6144, nullptr, 4, nullptr, 1);
  xTaskCreatePinnedToCore(usb_task, "usb", 6144, nullptr, 5, nullptr, 0);
  M5StackChan.Motion.move(0, kPitchMin, 300);
  show_status();
}

void loop() {
  M5StackChan.update();
  show_picture();
  show_status();
  delay(20);
}
