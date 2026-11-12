/* sysfs.c - read-only access to the ak_motor sysfs attributes and /proc.
 *
 * None of these functions ever open a /dev/motor* node or issue an ioctl.
 * Reading status must never move a motor, so all state here is gathered from
 * sysfs and /proc text files only. A test root directory may be prepended to
 * every path so the data can be mocked on the build host. */
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "motor.h"

void path_join(char *out, size_t n, const char *root, const char *rel)
{
    snprintf(out, n, "%s%s", root ? root : "", rel);
}

void sysfs_motor_path(char *out, size_t n, const char *root, int idx, const char *file)
{
    char rel[160];
    snprintf(rel, sizeof(rel), "/sys/devices/platform/motor%d/motor/%s", idx, file);
    path_join(out, n, root, rel);
}

void dev_motor_path(char *out, size_t n, const char *root, int idx)
{
    char rel[32];
    snprintf(rel, sizeof(rel), "/dev/motor%d", idx);
    path_join(out, n, root, rel);
}

int read_text(const char *path, char *buf, size_t n)
{
    int fd, len = 0;
    ssize_t r;

    if (n == 0)
        return -1;
    fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    while ((size_t)len < n - 1) {
        r = read(fd, buf + len, n - 1 - (size_t)len);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            close(fd);
            return -1;
        }
        if (r == 0)
            break;
        len += (int)r;
    }
    close(fd);
    buf[len] = '\0';
    return len;
}

/* Finds "<key>:" in text (the driver prints "key:value"), honoring leading
 * whitespace and allowing the key anywhere a line starts. Returns a pointer
 * just past the ':' or NULL. */
static const char *find_value(const char *text, const char *key)
{
    size_t kl = strlen(key);
    const char *p = text;

    while (*p) {
        const char *line = p;
        while (*line == ' ' || *line == '\t')
            line++;
        if (strncmp(line, key, kl) == 0 && line[kl] == ':')
            return line + kl + 1;
        /* advance to next line */
        while (*p && *p != '\n')
            p++;
        if (*p == '\n')
            p++;
    }
    return NULL;
}

int parse_key_int(const char *text, const char *key, int *val)
{
    const char *v = find_value(text, key);
    char *end;
    long n;

    if (!v)
        return -1;
    while (*v == ' ' || *v == '\t')
        v++;
    errno = 0;
    n = strtol(v, &end, 10);
    if (end == v || errno != 0)
        return -1;
    /* Allow only whitespace after the number. */
    while (*end) {
        if (*end != ' ' && *end != '\t' && *end != '\n' && *end != '\r')
            return -1;
        end++;
    }
    if (n < -2147483647L - 1 || n > 2147483647L)
        return -1;
    *val = (int)n;
    return 0;
}

int parse_key_str(const char *text, const char *key, char *out, size_t n)
{
    const char *v = find_value(text, key);
    size_t i = 0;

    if (!v || n == 0)
        return -1;
    while (*v == ' ' || *v == '\t')
        v++;
    while (v[i] && v[i] != '\n' && v[i] != '\r' && i < n - 1) {
        out[i] = v[i];
        i++;
    }
    /* trim trailing spaces */
    while (i > 0 && (out[i - 1] == ' ' || out[i - 1] == '\t'))
        i--;
    out[i] = '\0';
    return 0;
}

/* Reads one numeric sysfs attribute whose content is "<key>:<int>". */
static int read_attr_int(const char *root, int idx, const char *file,
                         const char *key, int *val)
{
    char path[256], buf[128];

    sysfs_motor_path(path, sizeof(path), root, idx, file);
    if (read_text(path, buf, sizeof(buf)) < 0)
        return -1;
    return parse_key_int(buf, key, val);
}

static int read_attr_str(const char *root, int idx, const char *file,
                         const char *key, char *out, size_t n)
{
    char path[256], buf[256];

    sysfs_motor_path(path, sizeof(path), root, idx, file);
    if (read_text(path, buf, sizeof(buf)) < 0)
        return -1;
    return parse_key_str(buf, key, out, n);
}

int sysfs_read_motor(const char *root, int idx, struct motor_info *mi)
{
    int found = 0;

    memset(mi, 0, sizeof(*mi));
    mi->index = idx;

    mi->have_pos = (read_attr_int(root, idx, "current_pos", "current-pos", &mi->pos) == 0);
    mi->have_total = (read_attr_int(root, idx, "total_steps", "total-steps", &mi->total) == 0);
    mi->have_boundary = (read_attr_int(root, idx, "boundary_steps", "boundary-steps", &mi->boundary) == 0);
    mi->have_speed = (read_attr_int(root, idx, "speed_step", "speed-hz", &mi->speed_hz) == 0);

    found = mi->have_pos + mi->have_total + mi->have_boundary + mi->have_speed;

    /* "part_numpber" is the driver's actual (misspelled) attribute name. */
    if (read_attr_str(root, idx, "part_numpber", "part-number", mi->part, sizeof(mi->part)) != 0)
        mi->part[0] = '\0';
    if (read_attr_str(root, idx, "hw_timer", "hw-timer", mi->hw_timer, sizeof(mi->hw_timer)) != 0)
        mi->hw_timer[0] = '\0';

    return found;
}

int sysfs_read_pos(const char *root, int idx, int *pos)
{
    return read_attr_int(root, idx, "current_pos", "current-pos", pos);
}

int proc_motor_major(const char *root)
{
    char path[256], buf[4096];
    const char *p;

    path_join(path, sizeof(path), root, "/proc/devices");
    if (read_text(path, buf, sizeof(buf)) < 0)
        return -1;

    p = buf;
    while (*p) {
        const char *line = p;
        int major;
        char name[64];
        while (*p && *p != '\n')
            p++;
        if (sscanf(line, "%d %63s", &major, name) == 2) {
            if (strcmp(name, "motor") == 0)
                return major;
        }
        if (*p == '\n')
            p++;
    }
    return -1;
}

int proc_module_line(const char *root, char *out, size_t n)
{
    char path[256], buf[8192];
    const char *p;

    path_join(path, sizeof(path), root, "/proc/modules");
    if (read_text(path, buf, sizeof(buf)) < 0)
        return -1;

    p = buf;
    while (*p) {
        const char *line = p;
        while (*p && *p != '\n')
            p++;
        if (strncmp(line, "ak_motor ", 9) == 0) {
            size_t len = (size_t)(p - line);
            if (len >= n)
                len = n - 1;
            memcpy(out, line, len);
            out[len] = '\0';
            return 0;
        }
        if (*p == '\n')
            p++;
    }
    return -1;
}
