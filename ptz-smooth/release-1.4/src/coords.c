/* coords.c - pure coordinate / speed / timeout math for the smooth bridge.
 * No I/O, no globals: exercised by tests/test_coords.c. */
#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "bridge.h"

int parse_speed_range(const char *s, double lo, double hi, double *out)
{
    char *end;
    double v;
    if (s == NULL || *s == '\0')
        return -1;
    errno = 0;
    v = strtod(s, &end);
    if (end == s || errno != 0)
        return -1;
    while (*end) {
        if (*end != ' ' && *end != '\t' && *end != '\n' && *end != '\r')
            return -1;
        end++;
    }
    if (!isfinite(v) || v < lo || v > hi)
        return -1;
    *out = v;
    return 0;
}

/* Parse a non-negative integer millisecond count (what the CGI passes to the
 * bridge). Empty/NULL -> def_ms. Clamped to [0, max_ms]. Rejects junk. */
int parse_timeout_ms(const char *s, long def_ms, long max_ms, long *out)
{
    char *end;
    long v;
    if (s == NULL || *s == '\0') { *out = def_ms; return 0; }
    errno = 0;
    v = strtol(s, &end, 10);
    if (end == s || errno != 0)
        return -1;
    while (*end) {
        if (*end != ' ' && *end != '\t' && *end != '\n' && *end != '\r')
            return -1;
        end++;
    }
    if (v < 0)
        return -1;
    if (v == 0) v = def_ms;        /* 0 means "use the default" */
    if (v > max_ms) v = max_ms;
    *out = v;
    return 0;
}

int speed_to_steps(double abs_speed, int step_unit, int max)
{
    long n;
    if (abs_speed < 0.0) abs_speed = -abs_speed;
    if (abs_speed > 1.0) abs_speed = 1.0;
    n = (long)lround(abs_speed * (double)step_unit);
    if (n < 0) n = 0;
    if (n > max) n = max;
    return (int)n;
}

double pos_to_norm(int pos, int total, int invert)
{
    double n;
    if (total <= 0) return 0.0;
    n = 2.0 * (double)pos / (double)total - 1.0;
    if (n < -1.0) n = -1.0;
    if (n >  1.0) n =  1.0;
    return invert ? -n : n;
}

int norm_to_steps(double norm, int total, int invert, int max)
{
    long n;
    if (total <= 0) return 0;
    if (norm < -1.0) norm = -1.0;
    if (norm >  1.0) norm =  1.0;
    if (invert) norm = -norm;
    n = (long)lround(norm * (double)total / 2.0);
    if (n >  max) n =  max;
    if (n < -max) n = -max;
    return (int)n;
}

int dir_motor(const char *dir)
{
    if (dir == NULL) return -1;
    if (strcmp(dir, "left") == 0 || strcmp(dir, "right") == 0) return MOTOR_PAN;
    if (strcmp(dir, "up") == 0 || strcmp(dir, "down") == 0) return MOTOR_TILT;
    return -1;
}

int dir_sign(const char *dir)
{
    if (dir == NULL) return 0;
    if (strcmp(dir, "right") == 0) return +1;
    if (strcmp(dir, "left")  == 0) return -1;
    if (strcmp(dir, "down")  == 0) return +1;
    if (strcmp(dir, "up")    == 0) return -1;
    return 0;
}

/* Duty-cycle budgeting: with a fixed-rate stepper, the average speed is set by
 * how many steps we allow per tick. A full-speed tick allows FULL_RATE*tick
 * steps; velocity scales that. Fractional leftovers carry in *budget so slow
 * speeds still advance smoothly over several ticks. */
int budget_steps(double abs_speed, double *budget, int tick_ms, int cap)
{
    double full, add;
    int n;
    if (abs_speed < 0.0) abs_speed = -abs_speed;
    if (abs_speed > 1.0) abs_speed = 1.0;
    full = (double)SM_FULL_RATE_HZ * (double)tick_ms / 1000.0;  /* steps/tick at full speed */
    add = abs_speed * full;
    *budget += add;
    n = (int)(*budget);
    if (n > cap) n = cap;
    if (n < 0) n = 0;
    *budget -= n;
    if (*budget > (double)cap) *budget = (double)cap;   /* don't accumulate unbounded */
    return n;
}
