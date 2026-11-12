# SMOOTH_PTZ_AUTOSTART_V1
# Appended to onvif/start.sh before its final exit. After ONVIF (httpd+wsd) is
# up, enable PTZ if the opt-in flag is present. No motor movement on activation.

if [ -f /mnt/onvif/ptz_autostart.enabled ] &&
   [ -f /mnt/onvif/scripts/enable-ptz.sh ]; then

    echo "=== Automatic PTZ activation ===" \
        >> /mnt/onvif/logs/ptz-autostart.log
    date >> /mnt/onvif/logs/ptz-autostart.log

    if sh /mnt/onvif/scripts/enable-ptz.sh \
        >> /mnt/onvif/logs/ptz-autostart.log 2>&1; then
        echo "PTZ activation successful" >> /mnt/onvif/logs/ptz-autostart.log
    else
        echo "ERROR: PTZ activation failed" >> /mnt/onvif/logs/ptz-autostart.log
    fi
fi
