// pocketctl — command-line gimbal control for DJI Osmo Pocket 3 in webcam mode.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#include "gimbal.h"

static gimbal_range rng;

static double clamp(double x, double lo, double hi) { return x < lo ? lo : x > hi ? hi : x; }

static void print_status(void) {
  double pan, tilt, roll;
  int zoom;
  if (gimbal_get(&pan, &tilt) == 0)
    printf("pan  %7.1f°  [%g, %g]\ntilt %7.1f°  [%g, %g]\n", pan, rng.pan_min, rng.pan_max,
           tilt, rng.tilt_min, rng.tilt_max);
  if (gimbal_get_zoom(&zoom) == 0) printf("zoom %7d   [%d, %d]\n", zoom, rng.zoom_min, rng.zoom_max);
  if (gimbal_get_roll(&roll) == 0) printf("roll %7.1f°\n", roll);
}

static struct termios saved_tio;
static void restore_tty(void) { tcsetattr(STDIN_FILENO, TCSANOW, &saved_tio); }

static void interactive(double step) {
  double pan, tilt;
  int zoom;
  if (gimbal_get(&pan, &tilt) || gimbal_get_zoom(&zoom)) return;

  tcgetattr(STDIN_FILENO, &saved_tio);
  atexit(restore_tty);
  struct termios raw = saved_tio;
  raw.c_lflag &= ~(ICANON | ECHO);
  tcsetattr(STDIN_FILENO, TCSANOW, &raw);

  printf("Arrows/WASD: move   [ ]: step -/+   +/-: zoom   c: center   r: refresh   q: quit\n");
  for (;;) {
    printf("\rpan %7.1f°  tilt %6.1f°  zoom %4d  step %4.1f°   ", pan, tilt, zoom, step);
    fflush(stdout);
    int ch = getchar();
    if (ch == 27 && getchar() == '[') {  // arrow keys: ESC [ A/B/C/D
      switch (getchar()) {
        case 'A': ch = 'w'; break;
        case 'B': ch = 's'; break;
        case 'C': ch = 'd'; break;
        case 'D': ch = 'a'; break;
      }
    }
    switch (ch) {
      case 'w': tilt += step; break;
      case 's': tilt -= step; break;
      case 'a': pan -= step; break;
      case 'd': pan += step; break;
      case ']': step = clamp(step * 2, 0.5, 45); continue;
      case '[': step = clamp(step / 2, 0.5, 45); continue;
      case 'c': pan = 0; tilt = 0; break;
      case 'r': gimbal_get(&pan, &tilt); continue;
      case '+': case '=': case '-':
        zoom = (int)clamp(zoom + (ch == '-' ? -1 : 1) * (rng.zoom_max - rng.zoom_min) / 10.0,
                          rng.zoom_min, rng.zoom_max);
        gimbal_set_zoom(zoom);
        continue;
      case 'q': case EOF: printf("\n"); return;
      default: continue;
    }
    pan = clamp(pan, rng.pan_min, rng.pan_max);
    tilt = clamp(tilt, rng.tilt_min, rng.tilt_max);
    gimbal_set(pan, tilt);
  }
}

static void usage(void) {
  fprintf(stderr,
          "usage: pocketctl [interactive [step]]  interactive control (arrow keys)\n"
          "       pocketctl get                   show current position and ranges\n"
          "       pocketctl set <pan> <tilt>      absolute angles in degrees\n"
          "       pocketctl move <dpan> <dtilt>   relative move in degrees\n"
          "       pocketctl center                pan 0, tilt 0\n"
          "       pocketctl zoom <value>          absolute zoom\n"
          "       pocketctl roll <deg>            absolute roll\n");
}

int main(int argc, char **argv) {
  if (gimbal_open(&rng)) {
    fprintf(stderr, "DJI Pocket 3 not found (is it in webcam mode?)\n");
    return 1;
  }

  const char *cmd = argc > 1 ? argv[1] : "interactive";
  if (!strcmp(cmd, "interactive")) {
    interactive(argc > 2 ? atof(argv[2]) : 5);
  } else if (!strcmp(cmd, "get")) {
    print_status();
  } else if (!strcmp(cmd, "set") && argc == 4) {
    return gimbal_set(atof(argv[2]), atof(argv[3])) ? 1 : 0;
  } else if (!strcmp(cmd, "move") && argc == 4) {
    double pan, tilt;
    if (gimbal_get(&pan, &tilt)) return 1;
    return gimbal_set(pan + atof(argv[2]), tilt + atof(argv[3])) ? 1 : 0;
  } else if (!strcmp(cmd, "center")) {
    return gimbal_set(0, 0) ? 1 : 0;
  } else if (!strcmp(cmd, "zoom") && argc == 3) {
    return gimbal_set_zoom(atoi(argv[2])) ? 1 : 0;
  } else if (!strcmp(cmd, "roll") && argc == 3) {
    return gimbal_set_roll(atof(argv[2])) ? 1 : 0;
  } else {
    usage();
    return 2;
  }
  return 0;
}
