/* bridge.h - onvif_ptz_bridge 1.1 (smooth): coords + daemon tuning.
 * The motor ABI/safety come from ptz-control's motor.h (included in bridge.c). */
#ifndef ONVIF_PTZ_BRIDGE_H
#define ONVIF_PTZ_BRIDGE_H

#include <stddef.h>

#define BRIDGE_VERSION "1.4.0"

/* ---- hardware speed policy (1.4) -------------------------------------
 * speed_step is set only via the verified SET_SPEED ioctl (0x40046d20); the
 * driver's sysfs speed_step is read-only, so the baseline can be restored only
 * by a clean close (re-SET to the default) or a reboot. See docs/SPEED_MAPPING.md.
 * Profiles (PTZ_SPEED_PROFILE): "compat" (default) issues NO SET_SPEED and
 * behaves exactly like 1.3; "hw" applies the configured per-axis speed_step;
 * "exp750" is "hw" with 750. 800 (factory tracking) is never selected
 * automatically and is above the hard ceiling below. */
#define SM_DEF_SPEED_STEP   600    /* factory default / restore target          */
#define SM_EXP_SPEED_STEP   750    /* the only tested experimental step          */
#define SM_SPEED_HARD_MAX   750    /* safety ceiling: never exceed (excludes 800) */
#define SM_SPEED_HARD_MIN   1

#define SPROFILE_COMPAT     0      /* no SET_SPEED; 1.3-identical                */
#define SPROFILE_HW         1      /* apply configured speed_step                */

#define BR_OK      0
#define BR_USAGE   1
#define BR_ENV     2
#define BR_FAIL    3

/* Axis -> motor index (confirmed on the camera). */
#define MOTOR_PAN   0
#define MOTOR_TILT  1

/* Confirmed physical directions:
 *   right -> motor0 +, left -> motor0 - ; down -> motor1 +, up -> motor1 -. */
#define TILT_INVERT 1
#define PAN_INVERT  0

/* Smooth-motion tuning (defaults; overridable via env). The driver runs the
 * stepper at a fixed rate (~600 Hz), so ONVIF velocity is approximated by how
 * much of each control tick the motor is kept moving (duty cycle), not by a
 * real speed change. See docs/DRIVER_NOTES.md. */
/* 1.3 restores the PROVEN 1.1 movement scheduler (fixed cushion). The adaptive
 * cushion of 1.2 regressed on real hardware (see docs/REGRESSION_ANALYSIS.md):
 * its step-sized cushion shrank below what the driver needs to keep the
 * ak_ce_timer running continuously, so held moves could collapse to a near
 * stall. 1.3 keeps the fixed cushion and adds only READ-ONLY diagnostics. */
#define SM_TICK_MS          20     /* control-loop period while moving           */
#define SM_FULL_RATE_HZ     600    /* nominal per-tick budget base (steps/s)     */
#define SM_MAX_PER_TICK     12     /* per-tick feed cap = one tick of nominal drain */
#define SM_DIAG_MS          1000   /* period of the per-second diagnostic line   */
#define SM_DEF_TIMEOUT_MS   10000  /* default ContinuousMove deadline           */
#define SM_HARD_TIMEOUT_MS  60000  /* absolute ceiling on a motion deadline     */
#define SM_MARGIN           32     /* steps kept clear of each end-stop         */

/* ---- coords.c : pure, unit-tested ------------------------------------ */
int parse_speed_range(const char *s, double lo, double hi, double *out);
int parse_timeout_ms(const char *s, long def_ms, long max_ms, long *out);
int speed_to_steps(double abs_speed, int step_unit, int max);
double pos_to_norm(int pos, int total, int invert);
int norm_to_steps(double norm, int total, int invert, int max);
int dir_motor(const char *dir);
int dir_sign(const char *dir);
/* steps to issue this tick given velocity and a fractional budget carried
 * across ticks; returns the integer steps and updates *budget. */
int budget_steps(double abs_speed, double *budget, int tick_ms, int cap);

#endif
