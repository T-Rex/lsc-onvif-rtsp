# SMOOTH_PTZ_AUTOSTART_V1
# Appended to onvif/start.sh before its final exit. After ONVIF (httpd+wsd) is
# up, enable PTZ if the opt-in flag is present. No motor movement on activation.

# $BASE is set by start.sh (the dir this block is appended into) = <SD>/onvif,
# so PTZ autostart follows the card wherever it is mounted (/mnt or /tmp/sd).
if [ -f "$BASE/ptz_autostart.enabled" ] &&
   [ -f "$BASE/scripts/enable-ptz.sh" ]; then

    echo "=== Automatic PTZ activation ===" \
        >> "$BASE/logs/ptz-autostart.log"
    date >> "$BASE/logs/ptz-autostart.log"

    if sh "$BASE/scripts/enable-ptz.sh" \
        >> "$BASE/logs/ptz-autostart.log" 2>&1; then
        echo "PTZ activation successful" >> "$BASE/logs/ptz-autostart.log"
    else
        echo "ERROR: PTZ activation failed" >> "$BASE/logs/ptz-autostart.log"
    fi
fi
