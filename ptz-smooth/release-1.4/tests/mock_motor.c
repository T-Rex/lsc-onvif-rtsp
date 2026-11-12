/* mock_motor.c - host stand-in for ptz-control's device layer (dev_linux.c).
 *
 * Simulates the asynchronous ak_motor driver so the smooth daemon can be
 * tested without hardware: MOVE sets/extends a relative target and starts
 * "stepping"; the position advances toward the target at a fixed rate using
 * real elapsed time between STATUS calls; STOP/close halt it. The mock keeps
 * the sysfs current_pos file (read by sysfs.c) in sync, so position/boundary
 * logic sees the motion. Never touches real hardware.
 *
 * Env: PTZ_FAKE_FAIL=1 (MOVE fails), PTZ_NOSTATUS=1 (STATUS fails -> sysfs
 * fallback), PTZ_FAKE_RATE_HZ=N (step rate, default 600). */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "motor.h"

static char m_root[256] = "";

struct sim {
    int in_use;
    int motor;
    int pos, target, total, moving;
    int speed_step;          /* current speed_step (set via dev_set_speed)      */
    long last_ms;
};
static struct sim g_sim[2];

/* Model the real driver: speed_step is NOT 1:1 with current_pos rate. The
 * camera shows ~100 units/s at speed_step=600 (≈6:1). PTZ_FAKE_RATE_HZ overrides
 * this for tests that want a specific rate. */
static int sim_rate(const struct sim *s)
{
    int r;
    const char *v = getenv("PTZ_FAKE_RATE_HZ");
    const char *cap = getenv("PTZ_FAKE_RATE_CAP");
    if (v && *v) r = atoi(v) > 0 ? atoi(v) : 1;
    else { r = s->speed_step / 6; if (r < 1) r = 1; }
    /* Model the real-hardware ceiling: the step rate saturates regardless of
     * speed_step (the ak_ce_timer handler cost caps it ~105/s). */
    if (cap && *cap) { int c = atoi(cap); if (c > 0 && r > c) r = c; }
    return r;
}

static int envint(const char *n, int d){ const char *v=getenv(n); return v&&*v?atoi(v):d; }
static long now_ms(void){ struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return (long)t.tv_sec*1000+t.tv_nsec/1000000; }

static void spath(char *out, size_t n, int idx, const char *file)
{
    snprintf(out, n, "%s/sys/devices/platform/motor%d/motor/%s", m_root, idx, file);
}
static int readfile_int(int idx, const char *file, const char *key, int *v)
{
    char p[256], b[128]; FILE *f; const char *q;
    spath(p, sizeof(p), idx, file);
    f = fopen(p, "r"); if (!f) return -1;
    size_t r = fread(b, 1, sizeof(b)-1, f); fclose(f); b[r]='\0';
    q = strstr(b, key); if (!q) return -1; q += strlen(key); if (*q==':') q++;
    *v = atoi(q); return 0;
}
static void write_pos(int idx, int pos)
{
    char p[256]; FILE *f; spath(p, sizeof(p), idx, "current_pos");
    f = fopen(p, "w"); if (f) { fprintf(f, "current-pos:%d\n", pos); fclose(f); }
}

static struct sim *sim_for(int motor)
{
    struct sim *s = &g_sim[motor ? 1 : 0];
    if (!s->in_use) {
        s->in_use = 1; s->motor = motor; s->moving = 0;
        if (readfile_int(motor, "current_pos", "current-pos", &s->pos) != 0) s->pos = 0;
        if (readfile_int(motor, "total_steps", "total-steps", &s->total) != 0) s->total = 4096;
        if (readfile_int(motor, "speed_step", "speed-hz", &s->speed_step) != 0) s->speed_step = 600;
        s->target = s->pos; s->last_ms = now_ms();
    }
    return s;
}

/* advance the simulated position toward the target using elapsed real time */
static void advance(struct sim *s)
{
    long now = now_ms(), dt = now - s->last_ms;
    int rate = sim_rate(s);
    long steps;
    s->last_ms = now;
    if (!s->moving || dt <= 0) return;
    steps = (long)rate * dt / 1000;
    if (steps <= 0) return;
    if (s->pos < s->target) { s->pos += (int)steps; if (s->pos >= s->target) { s->pos = s->target; s->moving = 0; } }
    else if (s->pos > s->target) { s->pos -= (int)steps; if (s->pos <= s->target) { s->pos = s->target; s->moving = 0; } }
    else s->moving = 0;
    if (s->pos < 0) s->pos = 0;
    if (s->pos > s->total) s->pos = s->total;
    write_pos(s->motor, s->pos);
}

void dev_set_root(const char *root){ snprintf(m_root, sizeof(m_root), "%s", root ? root : ""); }

int dev_check_node(const char *root, const char *path, int idx, char *err, size_t errn)
{
    FILE *f = fopen(path, "r");
    (void)root; (void)idx;
    if (!f) { snprintf(err, errn, "%s: %s", path, strerror(errno)); return EX_ENV; }
    fclose(f);
    return EX_OK;
}

int dev_open(const char *path)
{
    const char *b = strrchr(path, '/'); b = b ? b+1 : path;
    int idx = (strncmp(b, "motor", 5) == 0) ? atoi(b+5) : 0;
    struct sim *s = sim_for(idx);
    s->last_ms = now_ms();
    return 100 + idx;
}

int dev_move(int fd, int32_t steps)
{
    struct sim *s = sim_for(fd - 100);
    if (envint("PTZ_FAKE_FAIL", 0)) return -EIO;
    advance(s);
    s->target = s->pos + steps;          /* relative move, extends current run */
    if (s->target < 0) s->target = 0;
    if (s->target > s->total) s->target = s->total;
    s->moving = (s->target != s->pos);
    return 0;
}

int dev_stop(int fd)
{
    struct sim *s = sim_for(fd - 100);
    advance(s);
    s->target = s->pos; s->moving = 0;
    write_pos(s->motor, s->pos);
    return 0;
}

int dev_get_status(int fd, struct ak_motor_status *st)
{
    struct sim *s = sim_for(fd - 100);
    memset(st, 0, sizeof(*st));
    if (envint("PTZ_NOSTATUS", 0)) return -ENOTTY;
    advance(s);
    st->moving = s->moving;
    st->current_pos = s->pos;
    st->total_steps = s->total;
    /* driver-reported speed: the stored speed_step, unless a test forces a
     * different reported value ("driver reports different from requested"). */
    { const char *d = getenv("PTZ_FAKE_DRV_SPEED"); st->speed_hz = (d && *d) ? atoi(d) : s->speed_step; }
    return 0;
}

void dev_close(int fd)
{
    struct sim *s = sim_for(fd - 100);
    advance(s);
    s->target = s->pos; s->moving = 0;   /* driver auto-stops on close */
    write_pos(s->motor, s->pos);
}

int dev_set_speed(int fd, int hz)
{
    struct sim *s = sim_for(fd - 100);
    if (envint("PTZ_FAKE_SPEED_FAIL", 0)) return -EIO;
    if (hz <= 0) return -EINVAL;
    advance(s);
    s->speed_step = hz;
    return 0;
}

void dev_sleep_ms(int ms)
{
    struct timespec t; t.tv_sec = ms/1000; t.tv_nsec = (long)(ms%1000)*1000000L;
    while (nanosleep(&t, &t) != 0 && errno == EINTR) ;
}
