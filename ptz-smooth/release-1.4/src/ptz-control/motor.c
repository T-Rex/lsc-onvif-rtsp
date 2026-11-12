/* motor.c - argument parsing, move planning and safety validation.
 *
 * Pure functions: no I/O, no device access. Everything here is exercised by
 * tests/test_motor.c on the build host. The actual ioctl is issued in the
 * device layer only after plan_move() has approved the request. */
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "motor.h"

int parse_motor_index(const char *s, int *out)
{
    if (s == NULL)
        return -1;
    if ((s[0] == '0' || s[0] == '1') && s[1] == '\0') {
        *out = s[0] - '0';
        return 0;
    }
    return -1;
}

int parse_steps(const char *s, long *out)
{
    const char *p = s;
    char *end;
    long n;

    if (s == NULL || *s == '\0')
        return -1;

    /* Strict: optional single sign, then digits only. No whitespace, no
     * 0x, no '+' followed by nothing. */
    if (*p == '+' || *p == '-')
        p++;
    if (*p == '\0')
        return -1;
    for (const char *q = p; *q; q++) {
        if (*q < '0' || *q > '9')
            return -1;
    }

    errno = 0;
    n = strtol(s, &end, 10);
    if (end == s || *end != '\0' || errno != 0)
        return -1;
    /* Reject absurd magnitudes before any limit logic runs. */
    if (n < -(long)HARD_MAX_STEPS * 1000 || n > (long)HARD_MAX_STEPS * 1000)
        return -1;

    *out = n;
    return 0;
}

void encode_move_arg(int32_t steps, unsigned char out[4])
{
    uint32_t u = (uint32_t)steps;
    out[0] = (unsigned char)(u & 0xff);
    out[1] = (unsigned char)((u >> 8) & 0xff);
    out[2] = (unsigned char)((u >> 16) & 0xff);
    out[3] = (unsigned char)((u >> 24) & 0xff);
}

int check_motor_info(const struct motor_info *mi, char *err, size_t errn)
{
    if (!mi->have_pos || !mi->have_total) {
        snprintf(err, errn, "motor %d: position/total_steps unavailable in sysfs", mi->index);
        return EX_ENV;
    }
    if (mi->total < MIN_TOTAL_STEPS || mi->total > MAX_TOTAL_STEPS) {
        snprintf(err, errn, "motor %d: total_steps %d out of sane range [%d,%d]",
                 mi->index, mi->total, MIN_TOTAL_STEPS, MAX_TOTAL_STEPS);
        return EX_ENV;
    }
    if (mi->have_boundary && (mi->boundary < 0 || mi->boundary * 2 >= mi->total)) {
        snprintf(err, errn, "motor %d: boundary_steps %d inconsistent with total %d",
                 mi->index, mi->boundary, mi->total);
        return EX_ENV;
    }
    if (mi->pos < 0 || mi->pos > mi->total) {
        snprintf(err, errn, "motor %d: current_pos %d outside [0,%d]; refusing to move",
                 mi->index, mi->pos, mi->total);
        return EX_ENV;
    }
    if (mi->have_speed && (mi->speed_hz < MIN_SPEED_HZ || mi->speed_hz > MAX_SPEED_HZ)) {
        snprintf(err, errn, "motor %d: speed_hz %d out of range [%d,%d]",
                 mi->index, mi->speed_hz, MIN_SPEED_HZ, MAX_SPEED_HZ);
        return EX_ENV;
    }
    return EX_OK;
}

int plan_move(const struct motor_info *mi, long steps, const struct limits *lim,
              struct move_plan *plan, char *err, size_t errn)
{
    int rc, boundary, lo, hi;
    long target;

    rc = check_motor_info(mi, err, errn);
    if (rc != EX_OK)
        return rc;

    if (lim->max_steps < 1 || lim->max_steps > HARD_MAX_STEPS) {
        snprintf(err, errn, "internal: max_steps %ld out of [1,%d]", lim->max_steps, HARD_MAX_STEPS);
        return EX_USAGE;
    }
    if (lim->margin < 0) {
        snprintf(err, errn, "internal: negative margin");
        return EX_USAGE;
    }

    if (steps == 0) {
        snprintf(err, errn, "step count is 0: nothing to do");
        return EX_USAGE;
    }
    if (steps > lim->max_steps || steps < -lim->max_steps) {
        snprintf(err, errn, "step count %ld exceeds the limit of %ld (use --max-steps to raise, up to %d)",
                 steps, lim->max_steps, HARD_MAX_STEPS);
        return EX_USAGE;
    }

    boundary = mi->have_boundary ? mi->boundary : 0;

    /* Keep clear of the driver's end-stops by the safety margin. The driver
     * itself would stop at [boundary, total-boundary], but we refuse to
     * approach that boundary so a miscounted position cannot drive the
     * mechanism into a hard stop. */
    lo = boundary + lim->margin;
    hi = mi->total - boundary - lim->margin;
    if (lo > hi) {
        /* Range too small for this margin: fall back to the driver limits
         * but never beyond them. */
        lo = boundary;
        hi = mi->total - boundary;
    }

    target = (long)mi->pos + steps;
    if (target < lo || target > hi) {
        snprintf(err, errn,
                 "move rejected: target %ld outside safe range [%d,%d] "
                 "(pos %d, total %d, boundary %d, margin %d)",
                 target, lo, hi, mi->pos, mi->total, boundary, lim->margin);
        return EX_USAGE;
    }

    memset(plan, 0, sizeof(*plan));
    plan->index = mi->index;
    plan->steps = steps;
    plan->pos = mi->pos;
    plan->total = mi->total;
    plan->boundary = boundary;
    plan->speed_hz = mi->have_speed ? mi->speed_hz : 0;
    plan->lo = lo;
    plan->hi = hi;
    plan->target = target;
    plan->ioctl_arg = (int32_t)steps;
    plan->request = AK_MOTOR_IOC_MOVE;

    /* Timeout for the whole move: steps / speed plus generous slack. At the
     * default 600 Hz, 20 steps take ~33 ms; clamp to a sane window. */
    {
        int hz = plan->speed_hz > 0 ? plan->speed_hz : 100;
        long ms = (labs(steps) * 1000) / hz;
        ms = ms * 4 + 2000;          /* ramps + poll slack */
        if (ms < 2000) ms = 2000;
        if (ms > 30000) ms = 30000;
        plan->timeout_ms = (int)ms;
    }

    return EX_OK;
}
