/* dev_linux.c - the only code that opens /dev/motor* and issues ioctls.
 *
 * Compiled into the target binary. The host unit tests link tests/mock_dev.c
 * instead, so plan_move()/sysfs parsing can be tested without real devices
 * (and the test build never contains a single motor ioctl). */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <time.h>
#include <unistd.h>

#include "motor.h"

void dev_set_root(const char *root) { (void)root; }   /* real devices need no root */

int dev_check_node(const char *root, const char *path, int idx, char *err, size_t errn)
{
    struct stat st;
    int major;

    if (stat(path, &st) != 0) {
        snprintf(err, errn, "%s: %s", path, strerror(errno));
        return EX_ENV;
    }
    if (!S_ISCHR(st.st_mode)) {
        snprintf(err, errn, "%s is not a character device", path);
        return EX_ENV;
    }
    major = proc_motor_major(root);
    if (major < 0) {
        snprintf(err, errn, "no \"motor\" device class in /proc/devices (is ak_motor loaded?)");
        return EX_ENV;
    }
    if ((int)major(st.st_rdev) != major) {
        snprintf(err, errn, "%s major %d != ak_motor major %d",
                 path, (int)major(st.st_rdev), major);
        return EX_ENV;
    }
    if ((int)minor(st.st_rdev) != idx) {
        snprintf(err, errn, "%s minor %d != motor index %d",
                 path, (int)minor(st.st_rdev), idx);
        return EX_ENV;
    }
    return EX_OK;
}

/* anyka_ipc opens the nodes O_RDONLY and still issues move/stop ioctls, so a
 * read-only descriptor is enough and avoids requesting write access we do not
 * need. */
int dev_open(const char *path)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -errno;
    return fd;
}

int dev_move(int fd, int32_t steps)
{
    int32_t arg = steps;
    if (ioctl(fd, AK_MOTOR_IOC_MOVE, &arg) != 0)
        return -errno;
    return 0;
}

int dev_stop(int fd)
{
    int32_t arg = 0;
    if (ioctl(fd, AK_MOTOR_IOC_STOP, &arg) != 0)
        return -errno;
    return 0;
}

/* Experimental hardware-speed control. Only the experimental onvif_ptz_bridge
 * build calls this; ptz_control and the stable bridge never do. */
int dev_set_speed(int fd, int hz)
{
    int32_t arg = hz;
    if (ioctl(fd, AK_MOTOR_IOC_SET_SPEED, &arg) != 0)
        return -errno;
    return 0;
}

int dev_get_status(int fd, struct ak_motor_status *st)
{
    memset(st, 0, sizeof(*st));
    if (ioctl(fd, AK_MOTOR_IOC_GET_STATUS, st) != 0)
        return -errno;
    return 0;
}

void dev_close(int fd)
{
    if (fd >= 0)
        close(fd);
}

void dev_sleep_ms(int ms)
{
    struct timespec ts;
    ts.tv_sec = ms / 1000;
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR)
        ;
}
