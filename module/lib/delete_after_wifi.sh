#!/system/bin/sh
# Delete the properties the emulated Wi-Fi needs, once it no longer needs them.
#
# ro.boot.qemu.virtiowifi is read when the Wi-Fi HAL starts. Measured on the
# target: the HAL at 8.50s and wificond at 9.72s, against post-fs-data at ~5s and
# post-mount at 7.4s. Deleting it at either of those stages means the HAL never
# sees it, the AVD comes up with no wlan0 at all, and vdinfos scores the result --
# ConnectivityManager reports 'mobile' while the route is 'ethernet', a
# contradiction that is absent with the module uninstalled.
#
# Deleting it afterwards costs nothing: measured on a running device with Wi-Fi
# up, the property went empty and wlan0 kept its address.
#
# Sourced by post-mount.sh and run in the background, so a device whose Wi-Fi
# never comes up waits here rather than in the boot path.

# The CLI the prerequisite publishes late is not used: generate_rules.sh explains
# why the raw path is taken instead.
NOEMULATOR_AFTER_WIFI_RESETPROP=/data/adb/ksu/bin/resetprop

# Longer than any boot measured on the target, and bounded so that an image with
# no emulated Wi-Fi still gets its properties deleted rather than keeping them
# forever. On such an image the wait is the whole 30s and the properties are
# readable until then, which is the cost of not knowing in advance.
NOEMULATOR_AFTER_WIFI_TIMEOUT=30

noemulator_wait_for_wlan() {
    noemulator_waited=0
    while [ ! -e /sys/class/net/wlan0 ]; do
        [ "$noemulator_waited" -lt "$NOEMULATOR_AFTER_WIFI_TIMEOUT" ] || return 1
        noemulator_waited=$((noemulator_waited + 1))
        sleep 1
    done
    return 0
}

noemulator_delprop_after_wifi() {
    "$NOEMULATOR_AFTER_WIFI_RESETPROP" -d "$1" || echo "failed: delprop_after_wifi $1"
}

noemulator_delete_after_wifi() {
    after_wifi_rules="$1"

    if noemulator_wait_for_wlan; then
        after_wifi_reason="wlan0 up"
    else
        after_wifi_reason="timed out after ${NOEMULATOR_AFTER_WIFI_TIMEOUT}s with no wlan0"
    fi

    while IFS= read -r after_wifi_rule; do
        [ -n "$after_wifi_rule" ] || continue
        eval "$after_wifi_rule"
    done < "$after_wifi_rules"
    rm -f "$after_wifi_rules"

    # Deleting a property leaves its name orphaned in the raw property area, which
    # an enumerating reader still sees. post-fs-data.sh rebuilds the areas for the
    # same reason; these deletions happen after it has run, so they need their own.
    "$NOEMULATOR_AFTER_WIFI_RESETPROP" -c --force

    echo "delprop_after_wifi done ($after_wifi_reason) uptime=$(cut -d' ' -f1 /proc/uptime)"
}
