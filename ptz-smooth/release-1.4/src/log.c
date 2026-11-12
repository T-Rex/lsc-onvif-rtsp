/* log.c - see log.h. POSIX, no threads (the daemon is single-threaded). */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "log.h"

static FILE *g_fp = NULL;
static int   g_level = LOG_INFO;
static long  g_max = 0;
static char  g_path[256] = "";

void log_set_level(int level) { g_level = level; }

void log_open(const char *path, int level, long max_bytes)
{
    g_level = level;
    g_max = max_bytes;
    g_path[0] = '\0';
    if (path && *path) {
        snprintf(g_path, sizeof(g_path), "%s", path);
        g_fp = fopen(g_path, "a");
    }
    /* fall back to stderr if the file cannot be opened */
}

void log_close(void)
{
    if (g_fp) { fclose(g_fp); g_fp = NULL; }
}

static void rotate_if_needed(void)
{
    struct stat st;
    char bak[300];
    if (!g_fp || g_max <= 0 || g_path[0] == '\0')
        return;
    if (fstat(fileno(g_fp), &st) != 0 || st.st_size < g_max)
        return;
    fclose(g_fp);
    snprintf(bak, sizeof(bak), "%s.1", g_path);
    rename(g_path, bak);            /* keep one previous generation */
    g_fp = fopen(g_path, "a");
}

void log_msg(int level, const char *fmt, ...)
{
    FILE *out;
    va_list ap;
    char ts[32];
    time_t t;
    struct tm *tm;
    static const char *lvl[] = { "ERROR", "INFO", "DEBUG" };

    if (level > g_level)
        return;

    rotate_if_needed();
    out = g_fp ? g_fp : stderr;

    t = time(NULL);
    tm = gmtime(&t);
    if (tm)
        strftime(ts, sizeof(ts), "%Y-%m-%dT%H:%M:%SZ", tm);
    else
        snprintf(ts, sizeof(ts), "?");

    fprintf(out, "%s [%s] ", ts, lvl[level < 0 ? 0 : (level > 2 ? 2 : level)]);
    va_start(ap, fmt);
    vfprintf(out, fmt, ap);
    va_end(ap);
    fputc('\n', out);
    fflush(out);
}
