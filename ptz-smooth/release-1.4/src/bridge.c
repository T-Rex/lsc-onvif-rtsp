/* bridge.c - onvif_ptz_bridge 1.4 (smooth PTZ for the LSC 3007325)
 *
 * 1.4 builds on the PROVEN 1.3 movement scheduler (fixed cushion; the 1.2
 * adaptive cushion regressed on hardware, see docs/REGRESSION_ANALYSIS.md) and
 * folds the former experimental hardware-speed path into ONE binary, gated by a
 * runtime speed PROFILE:
 *   compat (default) - never issues SET_SPEED; byte-for-byte the 1.3 behaviour.
 *   hw               - applies a configured per-axis speed_step (clamped to a
 *                      per-axis limit and a hard ceiling that excludes 800), and
 *                      restores the default on release. Redundant SET_SPEEDs are
 *                      skipped. Default off, so an unconfigured 1.4 == 1.3.
 *
 * Smooth motion: motor0/motor1 are opened once per motion session and kept
 * open. MOVE (0x40046d40) is asynchronous and the driver *extends* a
 * same-direction move that is still running, so the loop feeds a small,
 * velocity-scaled number of steps every SM_TICK_MS (<= one tick of drain), and
 * the motor never stops between feeds. The commanded target leads the position
 * by at most ~one tick, bounding worst-case stop latency.
 *
 * Velocity: the driver steps at a fixed rate, so ONVIF velocity is approximated
 * by duty cycle (steps fed per tick), not a real speed change (see
 * docs/DRIVER_NOTES.md and docs/SPEED_MAPPING.md). speed_step changes the motor
 * step rate directly via SET_SPEED and never requires restarting an active move.
 *
 * CLI (unchanged):
 *   daemon
 *   right|left|up|down <speed> [timeout_ms]     (timeout appended by the CGI)
 *   rel <dx> <dy>
 *   stop all|pantilt
 *   position | is_moving | status | ping | shutdown
 *
 * Safety: only the verified MOVE/STOP/STATUS/SET_SPEED ioctls (via ptz-control's
 * device layer); bounds from sysfs with SM_MARGIN; positions are range-checked
 * (stale/garbage readings stop the axis); a monotonic deadline stops a held
 * direction that is never refreshed; Stop has priority and cancels future feeds;
 * no motion at startup; the motor fds are closed (driver auto-stop) on
 * shutdown/termination, which also restores the default speed_step. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "bridge.h"
#include "log.h"
#include "motor.h"          /* ptz-control: dev_*, sysfs_*, struct ak_motor_status */

/* ------------------------------------------------------------- config/env */
static const char *env_or(const char *n, const char *d){ const char *v=getenv(n); return (v&&*v)?v:d; }
static int env_int(const char *n, int d){ const char *v=getenv(n); if(!v||!*v) return d; int x=atoi(v); return x>0?x:d; }
static const char *sock_path(void){ return env_or("PTZ_SOCK","/tmp/onvif/run/ptz.sock"); }
static const char *pid_path(void){ return env_or("PTZ_PIDFILE","/tmp/onvif/run/ptz.pid"); }
static const char *root_pfx(void){ return env_or("PTZ_ROOT",""); }
static const char *log_path(void){ return env_or("PTZ_LOG","/mnt/onvif/logs/onvif_ptz_bridge.log"); }

static int g_tick_ms, g_max_per_tick, g_margin;
static long g_def_timeout, g_hard_timeout;
/* speed policy (1.4): default profile = compat (no SET_SPEED, == 1.3). */
static int g_speed_profile;                    /* SPROFILE_COMPAT / SPROFILE_HW   */
static int g_pan_speed_step, g_tilt_speed_step;/* per-axis targets when profile=hw */
static int g_pan_speed_max,  g_tilt_speed_max; /* per-axis clamps                  */
static long g_start_ms;                        /* daemon start -> uptime           */
static char g_last_error[160] = "";            /* last error (read-only diagnostic)*/
/* scheduler-level diagnostics (read-only) */
static long g_loop_last_ms, g_loop_n, g_loop_sum_ms, g_loop_max_ms, g_loop_missed;

static long now_ms(void){ struct timespec ts; clock_gettime(CLOCK_MONOTONIC,&ts); return (long)ts.tv_sec*1000+ts.tv_nsec/1000000; }

static void set_error(const char *fmt, ...)
{
    va_list ap; va_start(ap, fmt);
    vsnprintf(g_last_error, sizeof(g_last_error), fmt, ap);
    va_end(ap);
}
static const char *profile_name(void){ return g_speed_profile==SPROFILE_HW ? "hw" : "compat"; }

/* ------------------------------------------------------------- motion lock */
/* Exclude manual ptz_control while the daemon is driving the motors. Held only
 * while at least one axis is open. */
static int g_lockfd = -1;
static int motion_lock(void)
{
    char p[256];
    if (g_lockfd >= 0) return 0;
    snprintf(p, sizeof(p), "%s/tmp/ptz_control.lock", root_pfx());
    g_lockfd = open(p, O_CREAT|O_RDWR|O_CLOEXEC, 0600);
    if (g_lockfd < 0) return 0;              /* lock best-effort */
    if (flock(g_lockfd, LOCK_EX|LOCK_NB) != 0) { close(g_lockfd); g_lockfd=-1; return -1; }
    return 0;
}
static void motion_unlock(void){ if(g_lockfd>=0){ flock(g_lockfd,LOCK_UN); close(g_lockfd); g_lockfd=-1; } }

/* ------------------------------------------------------------- axis state */
struct axis {
    int motor;          /* MOTOR_PAN / MOTOR_TILT */
    int fd;             /* -1 = closed */
    int active;
    int dir;            /* +1 / -1 */
    double speed;       /* 0..1 */
    long deadline;      /* monotonic ms */
    int lo, hi, total;  /* safe bounds [margin, total-margin] */
    int cmd_dest;       /* absolute target last commanded to the driver (1.1) */
    int primed;         /* 1 once the fixed cushion is established (1.1)       */
    double budget;      /* fractional velocity-budget carry (1.1)             */
    int speed_step;     /* speed_step the bridge believes is in effect        */
    int applied_speed;  /* speed_step last SET via ioctl (0 = none applied)   */
    /* ---- READ-ONLY diagnostics (never affect scheduling) ---- */
    int   last_pos;     /* position at the previous tick                      */
    long  last_ms;      /* time of the previous tick                          */
    double rate_ema;    /* observed step rate (steps/s), EMA -- display only  */
    long  move_ioctls, stop_ioctls;
    long  move_start_ms, move_ms;   /* time spent moving in this session       */
    long  diag_ms; int diag_pos0;   /* per-second window                       */
    long  diag_loops, diag_moves, diag_cmd_steps;
    int   drv_speed;                /* speed_step the driver reports (STATUS)   */
    long  first_step_ms;            /* move-start -> first observed step (ms)   */
    long  last_move_ms;             /* time of the previous MOVE ioctl          */
    long  gap_sum, gap_max, gap_n;  /* inter-MOVE ioctl interval stats          */
    long  stop_lat_ms;              /* duration of the last (blocking) STOP     */
    long  drv_errors;               /* MOVE/STATUS/SET_SPEED ioctl failures     */
};
static struct axis g_ax[2];

static const char *mdev(int idx){ static char p[64]; snprintf(p,sizeof(p),"%s/dev/motor%d", root_pfx(), idx); return p; }

static void axis_init(struct axis *a, int motor){ memset(a,0,sizeof(*a)); a->motor=motor; a->fd=-1; a->speed_step=SM_DEF_SPEED_STEP; a->applied_speed=0; }

/* Target speed_step for an axis under profile=hw, clamped to the per-axis limit
 * and the hard ceiling (which excludes the 800 factory-tracking value). */
static int axis_target_step(const struct axis *a)
{
    int want = (a->motor == MOTOR_PAN) ? g_pan_speed_step : g_tilt_speed_step;
    int mx   = (a->motor == MOTOR_PAN) ? g_pan_speed_max  : g_tilt_speed_max;
    if (want < SM_SPEED_HARD_MIN) want = SM_DEF_SPEED_STEP;
    if (mx   > SM_SPEED_HARD_MAX) mx   = SM_SPEED_HARD_MAX;
    if (mx   < SM_SPEED_HARD_MIN) mx   = SM_SPEED_HARD_MIN;
    if (want > mx) want = mx;
    return want;
}

static int axis_open(struct axis *a)
{
    char err[160];
    struct motor_info mi;
    if (a->fd >= 0) return 0;
    if (motion_lock() != 0) { set_error("motor busy: ptz lock held"); LOGE("motor busy: another process holds the ptz lock"); return -1; }
    if (dev_check_node(root_pfx(), mdev(a->motor), a->motor, err, sizeof(err)) != EX_OK) {
        set_error("motor%d node: %s", a->motor, err);
        LOGE("motor%d node: %s", a->motor, err);
        return -1;
    }
    a->fd = dev_open(mdev(a->motor));
    if (a->fd < 0) { set_error("open motor%d: %s", a->motor, strerror(-a->fd)); LOGE("open motor%d: %s", a->motor, strerror(-a->fd)); return -1; }
    sysfs_read_motor(root_pfx(), a->motor, &mi);
    a->total = mi.have_total ? mi.total : 0;
    if (a->total <= 0) { set_error("motor%d total_steps unavailable", a->motor); LOGE("motor%d total_steps unavailable", a->motor); dev_close(a->fd); a->fd=-1; return -1; }
    a->lo = g_margin;
    a->hi = a->total - g_margin;
    if (a->lo > a->hi) { a->lo = 0; a->hi = a->total; }
    a->drv_speed = mi.have_speed ? mi.speed_hz : SM_DEF_SPEED_STEP;
    a->speed_step = a->drv_speed;              /* reported baseline */

    /* Hardware speed: apply only under profile=hw, only when the target differs
     * from what we last applied (no redundant SET_SPEED). SET_SPEED writes the
     * driver's speed_step directly and does NOT restart an in-flight move. */
    if (g_speed_profile == SPROFILE_HW) {
        int want = axis_target_step(a);
        if (want > 0 && want != a->applied_speed) {
            int rc = dev_set_speed(a->fd, want);
            if (rc == 0) {
                a->applied_speed = want; a->speed_step = want;
                LOGI("motor%d speed_step set to %d (profile=hw)", a->motor, want);
            } else {
                a->drv_errors++;
                set_error("motor%d set_speed(%d) rc=%d", a->motor, want, rc);
                LOGE("motor%d set_speed(%d) failed rc=%d; keeping %d", a->motor, want, rc, a->speed_step);
            }
        } else if (want == a->applied_speed) {
            a->speed_step = want;              /* already applied; skip ioctl */
        }
    }
    return 0;
}

static void axis_close(struct axis *a)
{
    /* restore the default speed on release where we changed it (sysfs speed_step
     * is read-only, so this SET_SPEED is the only way back short of a reboot) */
    if (a->fd >= 0 && g_speed_profile == SPROFILE_HW &&
        a->applied_speed > 0 && a->applied_speed != SM_DEF_SPEED_STEP) {
        if (dev_set_speed(a->fd, SM_DEF_SPEED_STEP) == 0) {
            a->applied_speed = SM_DEF_SPEED_STEP;
            LOGI("motor%d speed_step restored to %d on release", a->motor, SM_DEF_SPEED_STEP);
        } else {
            a->drv_errors++; set_error("motor%d restore speed_step failed", a->motor);
            LOGE("motor%d restore speed_step to %d failed", a->motor, SM_DEF_SPEED_STEP);
        }
    }
    if (a->fd >= 0) { dev_close(a->fd); a->fd = -1; }   /* driver auto-stops on close */
}

/* stop one axis: issue STOP (best effort interrupt), cancel future feeds. */
static void axis_stop(struct axis *a, const char *why)
{
    if (a->active) {
        LOGI("motor%d stop (%s)", a->motor, why);
        if (a->move_start_ms) { a->move_ms += now_ms() - a->move_start_ms; a->move_start_ms = 0; }
    }
    a->active = 0;
    a->primed = 0;             /* a stale cushion must never cause a later feed */
    a->budget = 0;
    if (a->fd >= 0) {
        long t0 = now_ms();
        int rc = dev_stop(a->fd);
        a->stop_ioctls++;
        a->stop_lat_ms = now_ms() - t0;   /* STOP blocks until stopped: real latency */
        if (rc != 0) { a->drv_errors++; set_error("motor%d STOP rc=%d", a->motor, rc); }
        LOGD("motor%d STOP ioctl rc=%d latency=%ldms", a->motor, rc, a->stop_lat_ms);
    }
}

static int any_active(void){ return g_ax[0].active || g_ax[1].active; }

/* When no axis is moving, release the descriptors (driver auto-stops, speed
 * restored) and the motion lock so manual ptz_control can run again. */
static void release_if_idle(void)
{
    if (any_active()) return;
    axis_close(&g_ax[0]);
    axis_close(&g_ax[1]);
    motion_unlock();
}

static void stop_all(const char *why)
{
    LOGI("stop all (%s)", why);
    axis_stop(&g_ax[0], why);
    axis_stop(&g_ax[1], why);
    release_if_idle();
}

/* start/refresh a continuous direction on an axis. */
static int start_dir(const char *dir, double speed, long timeout_ms)
{
    int m = dir_motor(dir), s = dir_sign(dir);
    struct axis *a;
    if (m < 0 || s == 0) return -1;
    a = &g_ax[m == MOTOR_PAN ? 0 : 1];

    if (speed == 0.0) { axis_stop(a, "zero speed"); release_if_idle(); return 0; }

    if (axis_open(a) != 0) return -1;
    {
        int pos;
        /* Do NOT assume a position: an unreadable or out-of-range reading means
         * stale/garbage state (e.g. after a driver error or unexpected close) -
         * refuse rather than drive blind. */
        if (sysfs_read_pos(root_pfx(), a->motor, &pos) != 0) {
            set_error("motor%d position unreadable at start", a->motor);
            LOGE("motor%d position unreadable; refusing move", a->motor);
            axis_stop(a, "no position"); release_if_idle(); return -1;
        }
        if (pos < 0 || pos > a->total) {
            set_error("motor%d position %d out of range [0,%d]", a->motor, pos, a->total);
            LOGE("motor%d position %d out of range [0,%d]; refusing move", a->motor, pos, a->total);
            axis_stop(a, "bad position"); release_if_idle(); return -1;
        }
        if (!a->active || a->dir != s) {   /* new move or reversal */
            a->cmd_dest = pos;
            a->primed = 0;
            a->budget = 0;
            /* reset read-only diagnostics for the new session */
            a->last_pos = pos;
            a->last_ms = now_ms();
            a->rate_ema = 0.0;
            a->diag_ms = a->last_ms;
            a->diag_pos0 = pos;
            a->diag_loops = a->diag_moves = a->diag_cmd_steps = 0;
            a->move_start_ms = a->last_ms;
            a->first_step_ms = 0;
            a->last_move_ms = 0;
            a->gap_sum = a->gap_max = a->gap_n = 0;
        }
    }
    a->active = 1;
    a->dir = s;
    a->speed = speed < 0 ? -speed : speed;
    a->deadline = now_ms() + timeout_ms;
    if (!a->move_start_ms) a->move_start_ms = now_ms();
    LOGI("motor%d start dir=%+d speed=%.3f timeout=%ldms", a->motor, s, a->speed, timeout_ms);
    return 0;
}

/* Read-only per-tick instrumentation: measure the observed step rate (EMA, for
 * display) and emit the per-second diagnostic line. MUST NOT change any
 * scheduling decision. */
static void axis_instrument(struct axis *a, int pos, long t)
{
    long dms = t - a->last_ms;
    int dpos = a->dir > 0 ? (pos - a->last_pos) : (a->last_pos - pos);
    if (dms > 0 && dpos > 0) {
        double inst = (double)dpos * 1000.0 / (double)dms;
        a->rate_ema = (a->rate_ema <= 0.0) ? inst : (a->rate_ema * 0.8 + inst * 0.2);
    }
    a->last_pos = pos; a->last_ms = t;
    a->diag_loops++;

    if (t - a->diag_ms >= SM_DIAG_MS) {
        int wpos = a->dir > 0 ? (pos - a->diag_pos0) : (a->diag_pos0 - pos);
        double secs = (t - a->diag_ms) / 1000.0;
        double obs = secs > 0 ? wpos / secs : 0.0;
        LOGI("motor%d diag: pos=%d rate=%.0f cmd=%.0f steps/s moves=%ld stops=%ld "
             "remaining=%d speed_step=%d loops=%ld (%.0f/s) move_ms=%ld",
             a->motor, pos, obs, (secs>0? a->diag_cmd_steps/secs : 0.0),
             a->diag_moves, a->stop_ioctls,
             a->dir > 0 ? (a->cmd_dest - pos) : (pos - a->cmd_dest),
             a->speed_step, a->diag_loops, a->diag_loops/secs,
             a->move_ms + (a->move_start_ms ? (t - a->move_start_ms) : 0));
        LOGI("motor%d diag2: req_speed=%d drv_speed=%d first_step_ms=%ld "
             "move_gap_avg_ms=%ld move_gap_max_ms=%ld stop_lat_ms=%ld drv_errors=%ld",
             a->motor, a->speed_step, a->drv_speed, a->first_step_ms,
             a->gap_n ? a->gap_sum / a->gap_n : 0, a->gap_max, a->stop_lat_ms, a->drv_errors);
        a->diag_ms = t; a->diag_pos0 = pos;
        a->diag_loops = a->diag_moves = a->diag_cmd_steps = 0;
    }
}

/* one control tick for an active axis -- the PROVEN 1.1 scheduler (fixed
 * cushion, primed once, velocity-budgeted). Diagnostics are gathered after the
 * position read and never alter the decisions below. */
static void axis_tick(struct axis *a)
{
    struct ak_motor_status st;
    int pos = 0, n;
    long t = now_ms();

    if (!a->active) return;
    if (t >= a->deadline) { axis_stop(a, "deadline/watchdog"); return; }

    if (dev_get_status(a->fd, &st) == 0) {
        pos = st.current_pos;
        a->drv_speed = st.speed_hz;      /* driver-reported speed_step */
    } else if (sysfs_read_pos(root_pfx(), a->motor, &pos) != 0) {
        a->drv_errors++;
        set_error("motor%d status unreadable", a->motor);
        LOGE("motor%d status unreadable; stopping", a->motor);
        axis_stop(a, "status error");
        return;
    }

    /* Reject stale / garbage positions rather than drive on a bad reading. */
    if (pos < 0 || pos > a->total) {
        a->drv_errors++;
        set_error("motor%d position %d out of range [0,%d]", a->motor, pos, a->total);
        LOGE("motor%d position %d out of range [0,%d]; stopping", a->motor, pos, a->total);
        axis_stop(a, "bad position");
        return;
    }

    axis_instrument(a, pos, t);          /* read-only */
    /* time from move start to the first observed step */
    if (a->first_step_ms == 0 && a->move_start_ms && a->rate_ema > 0.0)
        a->first_step_ms = t - a->move_start_ms;

    if (a->dir > 0 && pos >= a->hi) { LOGI("motor%d boundary hi (%d>=%d)", a->motor, pos, a->hi); axis_stop(a,"boundary"); return; }
    if (a->dir < 0 && pos <= a->lo) { LOGI("motor%d boundary lo (%d<=%d)", a->motor, pos, a->lo); axis_stop(a,"boundary"); return; }

    {
        /* Fixed cushion = two ticks of nominal drain (1.1). Primed once at the
         * start of a session so a same-direction move (extended by the driver)
         * stays continuously fed; the cushion is bounded so stop latency is
         * about two ticks even if STOP does not interrupt an in-flight move. */
        int lead = 2 * g_max_per_tick;
        int est_remaining = a->dir > 0 ? (a->cmd_dest - pos) : (pos - a->cmd_dest);
        int room_dest, advance;
        if (est_remaining < 0) est_remaining = 0;

        if (!a->primed) {
            int room = a->dir > 0 ? (a->hi - pos) : (pos - a->lo);
            int fill = lead < room ? lead : room;
            if (fill <= 0) { axis_stop(a, "boundary"); return; }
            if (dev_move(a->fd, a->dir * fill) != 0) {
                a->drv_errors++;
                set_error("motor%d MOVE failed", a->motor);
                LOGE("motor%d MOVE failed; stopping", a->motor); axis_stop(a, "move error"); return; }
            a->cmd_dest = pos + a->dir * fill;
            a->primed = 1;
            a->move_ioctls++; a->diag_moves++; a->diag_cmd_steps += fill;
            { long g = a->last_move_ms ? t - a->last_move_ms : 0; if (g>0){ a->gap_sum+=g; a->gap_n++; if(g>a->gap_max)a->gap_max=g; } a->last_move_ms=t; }
            LOGD("motor%d prime %+d (pos=%d)", a->motor, a->dir*fill, pos);
            return;
        }

        /* steady state: refill the cushion, throttled by the velocity budget */
        n = budget_steps(a->speed, &a->budget, g_tick_ms, g_max_per_tick);
        if (n <= 0) return;                   /* paused this tick (low speed) */
        advance = n;
        if (est_remaining + advance > lead) advance = lead - est_remaining;
        if (advance <= 0) return;             /* cushion full; let it drain */
        room_dest = a->dir > 0 ? (a->hi - a->cmd_dest) : (a->cmd_dest - a->lo);
        if (advance > room_dest) advance = room_dest;
        if (advance <= 0) { axis_stop(a, "boundary"); return; }

        if (dev_move(a->fd, a->dir * advance) != 0) {
            a->drv_errors++;
            set_error("motor%d MOVE failed", a->motor);
            LOGE("motor%d MOVE failed; stopping", a->motor);
            axis_stop(a, "move error");
            return;
        }
        a->cmd_dest += a->dir * advance;
        a->move_ioctls++; a->diag_moves++; a->diag_cmd_steps += advance;
        { long g = a->last_move_ms ? t - a->last_move_ms : 0; if (g>0){ a->gap_sum+=g; a->gap_n++; if(g>a->gap_max)a->gap_max=g; } a->last_move_ms=t; }
        LOGD("motor%d feed %+d (pos=%d cmd_dest=%d)", a->motor, a->dir*advance, pos, a->cmd_dest);
    }
}

static void worker(void)
{
    axis_tick(&g_ax[0]);
    axis_tick(&g_ax[1]);
    release_if_idle();
}

/* ------------------------------------------------------------ rel move */
/* RelativeMove: one bounded nudge per axis (clamped small so it is quick and
 * the daemon does not block long), waited out synchronously. Documented
 * limitation: a large requested translation is clamped to a small nudge. */
static int rel_steps(int motor, double norm, int invert)
{
    struct motor_info mi;
    int s, pos, lo, hi;
    if (sysfs_read_motor(root_pfx(), motor, &mi) <= 0 || !mi.have_total) return 0;
    s = norm_to_steps(norm, mi.total, invert, g_max_per_tick * 4);
    if (s == 0) return 0;
    if (sysfs_read_pos(root_pfx(), motor, &pos) != 0) return 0;
    lo = g_margin; hi = mi.total - g_margin;
    if (pos + s < lo) s = lo - pos;
    if (pos + s > hi) s = hi - pos;
    return s;
}

static void do_rel(double dx, double dy)
{
    int sp = rel_steps(MOTOR_PAN, dx, PAN_INVERT);
    int st = rel_steps(MOTOR_TILT, dy, TILT_INVERT);
    int moved = 0, waited = 0;

    if (sp && axis_open(&g_ax[0]) == 0) { LOGI("rel pan %+d", sp);  if (dev_move(g_ax[0].fd, sp) == 0) moved = 1; else { g_ax[0].drv_errors++; set_error("rel pan MOVE failed"); } }
    if (st && axis_open(&g_ax[1]) == 0) { LOGI("rel tilt %+d", st); if (dev_move(g_ax[1].fd, st) == 0) moved = 1; else { g_ax[1].drv_errors++; set_error("rel tilt MOVE failed"); } }

    while (moved && waited < 500) {
        struct ak_motor_status s0, s1; int busy = 0;
        if (g_ax[0].fd >= 0 && dev_get_status(g_ax[0].fd, &s0) == 0 && s0.moving) busy = 1;
        if (g_ax[1].fd >= 0 && dev_get_status(g_ax[1].fd, &s1) == 0 && s1.moving) busy = 1;
        if (!busy) break;
        dev_sleep_ms(10);
        waited += 10;
    }
    axis_close(&g_ax[0]); axis_close(&g_ax[1]); motion_unlock();
}

/* ------------------------------------------------------------ position */
static int read_norm(double *x, double *y)
{
    struct motor_info m0, m1;
    int ok0 = sysfs_read_motor(root_pfx(), MOTOR_PAN, &m0) > 0 && m0.have_pos && m0.have_total && m0.total>0;
    int ok1 = sysfs_read_motor(root_pfx(), MOTOR_TILT, &m1) > 0 && m1.have_pos && m1.have_total && m1.total>0;
    if (!ok0 && !ok1) return -1;
    *x = ok0 ? pos_to_norm(m0.pos, m0.total, PAN_INVERT) : 0.0;
    *y = ok1 ? pos_to_norm(m1.pos, m1.total, TILT_INVERT) : 0.0;
    return 0;
}

/* Raw step positions for diagnostics (read-only). -1 if unreadable. */
static void read_pos_raw(int *pp, int *tp)
{
    if (sysfs_read_pos(root_pfx(), MOTOR_PAN,  pp) != 0) *pp = -1;
    if (sysfs_read_pos(root_pfx(), MOTOR_TILT, tp) != 0) *tp = -1;
}

/* Requested / driver speed_step reported in status (best-effort, read-only). */
static int axis_req_speed(const struct axis *a)
{
    if (g_speed_profile == SPROFILE_HW) return axis_target_step(a);
    return a->speed_step > 0 ? a->speed_step : SM_DEF_SPEED_STEP;
}
static int axis_drv_speed(const struct axis *a)
{
    if (a->drv_speed > 0) return a->drv_speed;
    return a->speed_step > 0 ? a->speed_step : SM_DEF_SPEED_STEP;
}

/* ------------------------------------------------------- request handling */
/* returns 1 keep running, 0 shutdown */
static int handle(char *line, int fd)
{
    char v[32]="", a1[64]="", a2[64]="", a3[64]="";
    int n = sscanf(line, "%31s %63s %63s %63s", v, a1, a2, a3);
    if (n < 1) { write(fd, "ERR\n", 4); return 1; }

    if (!strcmp(v,"right")||!strcmp(v,"left")||!strcmp(v,"up")||!strcmp(v,"down")) {
        double sp = 1.0; long tmo;
        if (n >= 2 && parse_speed_range(a1, -1.0, 1.0, &sp) != 0) { set_error("bad speed '%s'", a1); LOGE("bad speed '%s'", a1); write(fd,"ERR bad speed\n",14); return 1; }
        if (parse_timeout_ms(n>=3?a2:"", g_def_timeout, g_hard_timeout, &tmo) != 0) { set_error("bad timeout '%s'", a2); LOGE("bad timeout '%s'", a2); write(fd,"ERR bad timeout\n",16); return 1; }
        LOGI("req %s speed=%.3f timeout=%ldms", v, sp, tmo);
        if (start_dir(v, sp, tmo) != 0) { write(fd,"ERR\n",4); return 1; }
        write(fd,"OK\n",3); return 1;
    }
    if (!strcmp(v,"rel")) {
        double dx=0, dy=0;
        if (n<3 || parse_speed_range(a1,-1.0,1.0,&dx)!=0 || parse_speed_range(a2,-1.0,1.0,&dy)!=0) { write(fd,"ERR bad rel\n",12); return 1; }
        do_rel(dx, dy); write(fd,"OK\n",3); return 1;
    }
    /* Stop has priority: handled synchronously before the next worker tick,
     * cancels future feeds (axis_stop clears active/primed/budget), stops both
     * axes, and releases the devices. */
    if (!strcmp(v,"stop")) { LOGI("req stop %s", a1[0]?a1:"all"); stop_all("client stop"); write(fd,"OK\n",3); return 1; }
    if (!strcmp(v,"position")) { double x,y; char b[64]; if(read_norm(&x,&y)!=0){write(fd,"ERR\n",4);return 1;} int l=snprintf(b,sizeof(b),"%.4f,%.4f\n",x,y); write(fd,b,(size_t)l); return 1; }
    if (!strcmp(v,"is_moving")) { write(fd, any_active()?"1\n":"0\n", 2); return 1; }
    if (!strcmp(v,"status")) {
        double x=0,y=0; char b[2048]; long ln; int pp=-1, tp=-1;
        struct axis *p=&g_ax[0], *tl=&g_ax[1];
        read_norm(&x,&y);
        read_pos_raw(&pp, &tp);
        ln = g_loop_n > 0 ? g_loop_sum_ms / g_loop_n : 0;
        int l=snprintf(b,sizeof(b),
            "bridge %s\n"
            "version=%s\n"
            "uptime=%ld\n"
            "active_speed_profile=%s\n"
            "pan_active=%d tilt_active=%d\n"
            "position=%.4f,%.4f\n"
            "pan_position=%d tilt_position=%d\n"
            "pan_rate=%.0f steps/s\n"
            "tilt_rate=%.0f steps/s\n"
            "pan_command_rate=%d steps/s\n"
            "pan_speed_step=%d tilt_speed_step=%d\n"
            "pan_requested_speed=%d tilt_requested_speed=%d\n"
            "pan_driver_speed=%d tilt_driver_speed=%d\n"
            "pan_move_count=%ld tilt_move_count=%ld\n"
            "pan_stop_count=%ld tilt_stop_count=%ld\n"
            "pan_driver_errors=%ld tilt_driver_errors=%ld\n"
            "pan_move_ioctls=%ld pan_stop_ioctls=%ld\n"
            "tilt_move_ioctls=%ld tilt_stop_ioctls=%ld\n"
            "pan_move_ms=%ld tilt_move_ms=%ld\n"
            "pan_first_step_ms=%ld tilt_first_step_ms=%ld\n"
            "pan_move_gap_avg_ms=%ld pan_move_gap_max_ms=%ld\n"
            "pan_stop_lat_ms=%ld tilt_stop_lat_ms=%ld\n"
            "loop_interval_avg_ms=%ld loop_interval_max_ms=%ld loop_missed=%ld\n"
            "tick_ms=%d margin=%d def_timeout_ms=%ld hard_timeout_ms=%ld\n"
            "last_error=%s\n",
            BRIDGE_VERSION, BRIDGE_VERSION,
            (now_ms() - g_start_ms) / 1000,
            profile_name(),
            p->active, tl->active, x, y,
            pp, tp,
            p->rate_ema, tl->rate_ema,
            (p->active ? g_max_per_tick * (1000 / g_tick_ms) : 0),
            p->speed_step, tl->speed_step,
            axis_req_speed(p), axis_req_speed(tl),
            axis_drv_speed(p), axis_drv_speed(tl),
            p->move_ioctls, tl->move_ioctls,
            p->stop_ioctls, tl->stop_ioctls,
            p->drv_errors, tl->drv_errors,
            p->move_ioctls, p->stop_ioctls, tl->move_ioctls, tl->stop_ioctls,
            p->move_ms + (p->move_start_ms? now_ms()-p->move_start_ms:0),
            tl->move_ms + (tl->move_start_ms? now_ms()-tl->move_start_ms:0),
            p->first_step_ms, tl->first_step_ms,
            p->gap_n ? p->gap_sum/p->gap_n : 0, p->gap_max,
            p->stop_lat_ms, tl->stop_lat_ms,
            ln, g_loop_max_ms, g_loop_missed,
            g_tick_ms, g_margin, g_def_timeout, g_hard_timeout,
            g_last_error[0] ? g_last_error : "none");
        if (l < 0) l = 0; if ((size_t)l >= sizeof(b)) l = (int)sizeof(b)-1;
        write(fd,b,(size_t)l); return 1;
    }
    if (!strcmp(v,"ping")) { write(fd,"OK\n",3); return 1; }
    if (!strcmp(v,"shutdown")) { write(fd,"OK\n",3); return 0; }
    write(fd,"ERR unknown\n",12); return 1;
}

/* ----------------------------------------------------------------- daemon */
static volatile sig_atomic_t g_quit = 0;
static void on_sig(int s){ (void)s; g_quit = 1; }

static void write_pid(void){ char b[32]; int fd=open(pid_path(),O_CREAT|O_WRONLY|O_TRUNC|O_CLOEXEC,0644); if(fd>=0){int l=snprintf(b,sizeof(b),"%d\n",(int)getpid()); if(write(fd,b,(size_t)l)<0){} close(fd);} }

static int run_daemon(void)
{
    struct sockaddr_un addr; const char *sp = sock_path(); int lfd;

    dev_set_root(root_pfx());
    g_start_ms = now_ms();
    axis_init(&g_ax[0], MOTOR_PAN);
    axis_init(&g_ax[1], MOTOR_TILT);

    /* idempotent start */
    { int c=socket(AF_UNIX,SOCK_STREAM,0);
      if(c>=0){ memset(&addr,0,sizeof(addr)); addr.sun_family=AF_UNIX; snprintf(addr.sun_path,sizeof(addr.sun_path),"%s",sp);
        if(connect(c,(struct sockaddr*)&addr,sizeof(addr))==0){ close(c); fprintf(stderr,"daemon already running\n"); return 0; } close(c);}
      unlink(sp); }

    lfd = socket(AF_UNIX,SOCK_STREAM,0);
    if(lfd<0){ perror("socket"); return BR_ENV; }
    memset(&addr,0,sizeof(addr)); addr.sun_family=AF_UNIX; snprintf(addr.sun_path,sizeof(addr.sun_path),"%s",sp);
    if(bind(lfd,(struct sockaddr*)&addr,sizeof(addr))<0){ perror("bind"); close(lfd); return BR_ENV; }
    chmod(sp, 0600);
    if(listen(lfd,8)<0){ perror("listen"); close(lfd); return BR_ENV; }

    signal(SIGTERM,on_sig); signal(SIGINT,on_sig); signal(SIGPIPE,SIG_IGN);
    write_pid();
    log_open(log_path(), env_int("PTZ_LOG_DEBUG",0)?LOG_DEBUG:LOG_INFO, 256*1024);
    LOGI("onvif_ptz_bridge %s daemon up (tick=%dms max/tick=%d margin=%d def_to=%ldms profile=%s pan_step=%d tilt_step=%d)",
         BRIDGE_VERSION, g_tick_ms, g_max_per_tick, g_margin, g_def_timeout,
         profile_name(), axis_target_step(&g_ax[0]), axis_target_step(&g_ax[1]));

    while (!g_quit) {
        struct pollfd pfd = { lfd, POLLIN, 0 };
        int to = any_active() ? g_tick_ms : -1;    /* block when idle: no busy loop */
        int pr = poll(&pfd, 1, to);
        if (pr < 0) { if (errno==EINTR) continue; break; }
        if (pr > 0 && (pfd.revents & POLLIN)) {
            int cfd = accept(lfd, NULL, NULL);
            if (cfd >= 0) {
                char buf[160]; ssize_t r = read(cfd, buf, sizeof(buf)-1);
                if (r > 0) { buf[r]='\0'; if(!handle(buf, cfd)) g_quit=1; }
                close(cfd);
            }
        }
        if (any_active()) {
            /* scheduler-loop diagnostics (read-only): interval and missed
             * deadlines relative to the tick period */
            long t = now_ms();
            if (g_loop_last_ms) {
                long d = t - g_loop_last_ms;
                g_loop_n++; g_loop_sum_ms += d;
                if (d > g_loop_max_ms) g_loop_max_ms = d;
                if (d > g_tick_ms + g_tick_ms/2) g_loop_missed++;  /* >1.5 ticks */
            }
            g_loop_last_ms = t;
            worker();
        } else {
            g_loop_last_ms = 0;   /* reset interval tracking between sessions */
        }
    }

    LOGI("daemon shutting down");
    stop_all("shutdown");
    unlink(sp); unlink(pid_path());
    log_close();
    close(lfd);
    return BR_OK;
}

/* ----------------------------------------------------------------- client */
static int client(const char *line, int print_reply)
{
    struct sockaddr_un addr; int fd=socket(AF_UNIX,SOCK_STREAM,0); char rep[4096]; ssize_t r; size_t tot=0;
    if(fd<0) return BR_ENV;
    memset(&addr,0,sizeof(addr)); addr.sun_family=AF_UNIX; snprintf(addr.sun_path,sizeof(addr.sun_path),"%s",sock_path());
    if(connect(fd,(struct sockaddr*)&addr,sizeof(addr))<0){ fprintf(stderr,"onvif_ptz_bridge: no daemon at %s: %s\n",sock_path(),strerror(errno)); close(fd); return BR_ENV; }
    if(write(fd,line,strlen(line))<0){ close(fd); return BR_FAIL; }
    /* read the whole reply (status is multi-line and can exceed one read) */
    while (tot < sizeof(rep)-1 && (r = read(fd, rep+tot, sizeof(rep)-1-tot)) > 0)
        tot += (size_t)r;
    close(fd);
    rep[tot]='\0';
    if(print_reply){ fputs(rep,stdout); if(tot==0||rep[tot-1]!='\n') fputc('\n',stdout); }
    return strncmp(rep,"ERR",3)==0 ? BR_FAIL : BR_OK;
}

static void usage(FILE *f)
{
    fprintf(f,
"onvif_ptz_bridge " BRIDGE_VERSION "\n"
"  daemon\n"
"  right|left|up|down <speed> [timeout_ms]\n"
"  rel <dx> <dy>\n"
"  stop all|pantilt\n"
"  position | is_moving | status | ping | shutdown\n");
}

int main(int argc, char **argv)
{
    g_tick_ms      = env_int("PTZ_TICK_MS", SM_TICK_MS);
    g_max_per_tick = env_int("PTZ_MAX_PER_TICK", SM_MAX_PER_TICK);
    g_margin       = env_int("PTZ_MARGIN", SM_MARGIN);
    g_def_timeout  = env_int("PTZ_DEF_TIMEOUT_MS", SM_DEF_TIMEOUT_MS);
    g_hard_timeout = env_int("PTZ_HARD_TIMEOUT_MS", SM_HARD_TIMEOUT_MS);
    if (g_def_timeout > g_hard_timeout) g_def_timeout = g_hard_timeout;

    /* speed profile (default compat == 1.3). */
    {
        const char *pr = getenv("PTZ_SPEED_PROFILE");
        int def_step = SM_DEF_SPEED_STEP;
        g_speed_profile = SPROFILE_COMPAT;
        if (pr && *pr) {
            if (!strcmp(pr,"hw")) g_speed_profile = SPROFILE_HW;
            else if (!strcmp(pr,"exp750")) { g_speed_profile = SPROFILE_HW; def_step = SM_EXP_SPEED_STEP; }
            else if (!strcmp(pr,"compat")) g_speed_profile = SPROFILE_COMPAT;
        }
        /* backward compatibility with the experimental build's env */
        if (env_int("PTZ_HW_SPEED_ENABLED", 0)) g_speed_profile = SPROFILE_HW;
        g_pan_speed_step  = env_int("PTZ_PAN_SPEED_STEP",  def_step);
        g_tilt_speed_step = env_int("PTZ_TILT_SPEED_STEP", def_step);
        g_pan_speed_max   = env_int("PTZ_PAN_SPEED_MAX",   SM_SPEED_HARD_MAX);
        g_tilt_speed_max  = env_int("PTZ_TILT_SPEED_MAX",  SM_SPEED_HARD_MAX);
    }

    if (argc < 2) { usage(stderr); return BR_USAGE; }
    if (!strcmp(argv[1],"-h")||!strcmp(argv[1],"--help")) { usage(stdout); return BR_OK; }
    if (!strcmp(argv[1],"daemon")) return run_daemon();

    dev_set_root(root_pfx());
    char line[160]=""; for(int i=1;i<argc;i++){ if(i>1) strncat(line," ",sizeof(line)-strlen(line)-1); strncat(line,argv[i],sizeof(line)-strlen(line)-1); }
    strncat(line,"\n",sizeof(line)-strlen(line)-1);
    int pr = (!strcmp(argv[1],"position")||!strcmp(argv[1],"is_moving")||!strcmp(argv[1],"status"));
    return client(line, pr);
}
