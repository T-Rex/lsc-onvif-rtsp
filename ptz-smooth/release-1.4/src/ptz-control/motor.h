/* motor.h - ptz_control internal interfaces */
#ifndef PTZ_MOTOR_H
#define PTZ_MOTOR_H

#include <stddef.h>
#include <stdint.h>
#include "ak_motor_abi.h"

#define PTZ_VERSION "1.0.0"

/* Exit codes */
#define EX_OK       0
#define EX_USAGE    1   /* invalid arguments or rejected by a safety check */
#define EX_ENV      2   /* sysfs / device / driver missing or inconsistent */
#define EX_MOVE     3   /* movement failed, timed out or ended off target  */
#define EX_BUSY     4   /* another ptz_control holds the lock              */

/* Limits */
#define DEFAULT_MAX_STEPS   20     /* first-test limit                      */
#define HARD_MAX_STEPS      256    /* --max-steps can never exceed this     */
#define DEFAULT_MARGIN      32     /* steps kept clear of the driver limits */
#define MIN_TOTAL_STEPS     16
#define MAX_TOTAL_STEPS     100000
#define MIN_SPEED_HZ        1
#define MAX_SPEED_HZ        5000

/* ---- sysfs.c ---------------------------------------------------------- */

struct motor_info {
    int index;
    int have_pos, have_total, have_boundary, have_speed;
    int pos, total, boundary, speed_hz;
    char part[64];             /* empty if unavailable */
    char hw_timer[64];
    char pwm_tbl[160];
    char gpio[160];
};

/* Paths below the test root ("" on the camera). */
void path_join(char *out, size_t n, const char *root, const char *rel);
void sysfs_motor_path(char *out, size_t n, const char *root, int idx, const char *file);
void dev_motor_path(char *out, size_t n, const char *root, int idx);

/* Strictly parses "<key>:<int>" (as printed by the driver, trailing
 * whitespace allowed). Returns 0 and sets *val, or -1. */
int parse_key_int(const char *text, const char *key, int *val);
int parse_key_str(const char *text, const char *key, char *out, size_t n);

/* Reads a small text file. Returns length or -1. */
int read_text(const char *path, char *buf, size_t n);

/* Fills *mi from sysfs. Never opens a device. Returns number of the four
 * numeric fields found (0..4). */
int sysfs_read_motor(const char *root, int idx, struct motor_info *mi);

/* Reads only current_pos (used for the stability check). */
int sysfs_read_pos(const char *root, int idx, int *pos);

/* Character-device major registered as "motor" in /proc/devices, or -1. */
int proc_motor_major(const char *root);
/* Copies the "ak_motor ..." line of /proc/modules, returns 0 if found. */
int proc_module_line(const char *root, char *out, size_t n);

/* ---- motor.c (pure logic, unit tested) -------------------------------- */

/* Strict decimal parse: optional sign, digits only, no whitespace, fits in
 * long and in [-HARD_MAX_STEPS*1000, HARD_MAX_STEPS*1000]. */
int parse_steps(const char *s, long *out);
int parse_motor_index(const char *s, int *out);   /* "0" or "1" only */

struct limits {
    long max_steps;   /* |steps| allowed, 1..HARD_MAX_STEPS */
    int margin;       /* >= 0 */
};

struct move_plan {
    int index;
    long steps;
    int pos, total, boundary, speed_hz;
    int lo, hi;            /* permitted target range */
    long target;
    int32_t ioctl_arg;
    unsigned long request;
    int timeout_ms;
};

/* Validates a requested move against sysfs data and limits. Returns 0 and
 * fills *plan, or returns EX_USAGE / EX_ENV with a message in err. */
int plan_move(const struct motor_info *mi, long steps, const struct limits *lim,
              struct move_plan *plan, char *err, size_t errn);

/* Validates the info itself (used by plan_move and status). */
int check_motor_info(const struct motor_info *mi, char *err, size_t errn);

/* Encodes the int32 argument as the 4 little-endian bytes the kernel reads. */
void encode_move_arg(int32_t steps, unsigned char out[4]);

/* ---- device layer (dev_linux.c on target, tests/mock_dev.c in tests) -- */

/* Checks that path is the driver's character device for motor idx
 * (S_ISCHR, major == "motor" major from /proc/devices, minor == idx). */
void dev_set_root(const char *root);               /* no-op on target; mock uses it */
int dev_check_node(const char *root, const char *path, int idx, char *err, size_t errn);
int dev_open(const char *path);                    /* fd or -errno */
int dev_move(int fd, int32_t steps);               /* 0 or -errno  */
int dev_stop(int fd);                              /* 0 or -errno  */
int dev_set_speed(int fd, int hz);                 /* 0 or -errno; experimental */
int dev_get_status(int fd, struct ak_motor_status *st);  /* 0 or -errno */
void dev_close(int fd);
void dev_sleep_ms(int ms);

/* ---- main.c ----------------------------------------------------------- */
int ptz_main(int argc, char **argv);

#endif
