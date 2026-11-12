/*
 * ak_motor_abi.h - userspace ABI of the Anyka ak_motor driver
 * (ak_motor.ko, "version=1.0.04", vermagic 4.4.192V2.1, built from
 * .../os/driver/ak_motor/ak_motor_dev.c), as recovered from the supplied
 * module and cross-checked against anyka_ipc. See DRIVER_ANALYSIS.md.
 *
 * Only the three requests ptz_control actually issues are defined here.
 * The driver implements further requests (set parameters / position, set
 * speed, move without end-stop checks, homing, centring, endless cruise).
 * They are documented in DRIVER_ANALYSIS.md and deliberately NOT defined,
 * so that they cannot be issued by accident.
 *
 * Note: the request numbers all encode _IOW('m', n, int) (size 4), but the
 * driver ignores the encoded size and direction. AK_MOTOR_IOC_GET_STATUS
 * copies 32 bytes TO userspace, so its buffer must be a full
 * struct ak_motor_status.
 */
#ifndef AK_MOTOR_ABI_H
#define AK_MOTOR_ABI_H

#include <stdint.h>

/* arg: pointer to int32_t, signed relative step count.
 * > 0: position counter increases (driver direction 0),
 * < 0: position counter decreases (driver direction 1), 0: no-op.
 * Asynchronous: returns after starting the hardware timer. The driver stops
 * the movement when the counter reaches total_steps - boundary_steps or
 * boundary_steps (checked before and during the move). */
#define AK_MOTOR_IOC_MOVE        0x40046d40u

/* arg: pointer to int32 speed_step (Hz). Writes the driver's speed_step field
 * directly (the value sysfs `speed_step` reports); no range check in the
 * driver. Verified from ak_motor.ko jump-table slot 32 (handler stores the
 * user int at motor+0x50). Used ONLY by the experimental hardware-speed build;
 * the stable build never issues it. The related 0x40046d21 sets speed from a
 * deg/s value (hz = val*steps_per_circle/360, rejects <=0). NOTE: 0x40046d44 is
 * a NO-OP in this driver (jump-table default), despite being a candidate from
 * other Anyka cameras. */
#define AK_MOTOR_IOC_SET_SPEED   0x40046d20u

/* arg: ignored (pass 0). Decelerates (4-step ramp) and waits in the kernel,
 * uninterruptibly, until the motor reports stopped. No-op if stopped. */
#define AK_MOTOR_IOC_STOP        0x40046d42u

/* arg: pointer to struct ak_motor_status (32 bytes, written by the kernel).
 * Read-only: takes the motor mutex, copies fields, never moves. */
#define AK_MOTOR_IOC_GET_STATUS  0x40046d43u

/* Driver magic and the number range its switch table covers. Requests in
 * this range that the driver does not implement return 0 (success) without
 * doing anything, so "probing" requests is meaningless as well as unsafe. */
#define AK_MOTOR_IOC_BASE        0x40046d00u
#define AK_MOTOR_IOC_LAST        0x40046d63u

struct ak_motor_status {
    int32_t moving;            /* 1 while running (driver status != 2), else 0 */
    int32_t current_pos;       /* software step counter (sysfs current_pos)     */
    int32_t speed_hz;          /* step rate (sysfs speed_step "speed-hz")        */
    int32_t speed_deg;         /* speed_hz * 360 / steps_per_circle              */
    int32_t steps_per_circle;  /* DT "steps-one-circle" (not exported in sysfs)  */
    int32_t total_steps;       /* sysfs total_steps                              */
    int32_t boundary_steps;    /* sysfs boundary_steps                           */
    int32_t hw_timer;          /* DT "attach-timer" (sysfs hw_timer)             */
};

_Static_assert(sizeof(struct ak_motor_status) == 32, "driver copies exactly 32 bytes");

#define AK_MOTOR_COUNT 2

#endif
