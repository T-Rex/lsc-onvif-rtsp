/* log.h - tiny leveled logger with size-based rotation for the PTZ daemon. */
#ifndef PTZ_LOG_H
#define PTZ_LOG_H

#define LOG_ERROR 0
#define LOG_INFO  1
#define LOG_DEBUG 2

/* Open the log file (append). path NULL or "" -> stderr only. level sets the
 * threshold (default INFO). max_bytes > 0 enables rotation: when the file
 * exceeds it, it is renamed to <path>.1 and a fresh file is started. */
void log_open(const char *path, int level, long max_bytes);
void log_set_level(int level);
void log_close(void);

void log_msg(int level, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 2, 3)))
#endif
;

#define LOGE(...) log_msg(LOG_ERROR, __VA_ARGS__)
#define LOGI(...) log_msg(LOG_INFO,  __VA_ARGS__)
#define LOGD(...) log_msg(LOG_DEBUG, __VA_ARGS__)

#endif
