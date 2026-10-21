#!/system/bin/sh
# Delete properties that a vendor service sets after post-fs-data, once their
# readers have read them.
#
# The vendor.qemu.* properties do not exist yet at post-fs-data (~5s): the
# qemu-props service writes them, and it starts at 5.35s on the target
# (ro.boottime.qemu-props). A delprop at post-fs-data deletes nothing and the
# service writes them afterwards.
#
# Their readers act on them once, soon after they are set: init.ranchu.rc triggers
# copy the timezone and create the Bluetooth and UWB links as each is set, and the
# radio HAL opens the modem port when it starts, at 8.16s
# (ro.boottime.vendor.radio-ranchu). Measured on a running device: deleting all
# five left /dev/bluetooth0, /dev/hvc2 and persist.sys.timezone in place, nothing
# wrote them back within 60s, and restarting the camera stack gave the same four
# cameras with the same facings. The radio HAL is the exception: restarted without
# the modem property it does not stay up, which is why that property is opt-in.
#
# Sourced by post-mount.sh and run in the background, after the Wi-Fi waiter.

NOEMULATOR_ONCE_SET_RESETPROP=${NOEMULATOR_ONCE_SET_RESETPROP:-/data/adb/ksu/bin/resetprop}

# Bounded so a property that is never set does not keep the waiter alive.
NOEMULATOR_ONCE_SET_TIMEOUT=${NOEMULATOR_ONCE_SET_TIMEOUT:-30}

# How long a reader gets after the last property is set. qemu-props sets them at
# 5.35s and the slowest reader, the radio HAL, starts 2.8s later.
NOEMULATOR_ONCE_SET_SETTLE=${NOEMULATOR_ONCE_SET_SETTLE:-5}

noemulator_wait_for_set() {
    once_set_waited=0
    while [ -z "$(getprop "$1")" ]; do
        [ "$once_set_waited" -lt "$NOEMULATOR_ONCE_SET_TIMEOUT" ] || return 1
        once_set_waited=$((once_set_waited + 1))
        sleep 1
    done
    return 0
}

noemulator_delprop_once_set() {
    "$NOEMULATOR_ONCE_SET_RESETPROP" -d "$1" || echo "failed: delprop_once_set $1"
}

noemulator_delete_once_set() {
    once_set_rules="$1"

    # Each rule is "noemulator_delprop_once_set '<name>'"; the name is the
    # second field with its quotes removed.
    while IFS= read -r once_set_rule; do
        once_set_name=$(echo "$once_set_rule" | cut -d"'" -f2)
        noemulator_wait_for_set "$once_set_name" \
            || echo "delprop_once_set: $once_set_name never set within ${NOEMULATOR_ONCE_SET_TIMEOUT}s"
    done < "$once_set_rules"
    sleep "$NOEMULATOR_ONCE_SET_SETTLE"

    while IFS= read -r once_set_rule; do
        [ -n "$once_set_rule" ] || continue
        eval "$once_set_rule"
    done < "$once_set_rules"
    rm -f "$once_set_rules"

    # The same orphaned-name problem delete_after_wifi.sh rebuilds for.
    "$NOEMULATOR_ONCE_SET_RESETPROP" -c --force

    echo "delprop_once_set done uptime=$(cut -d' ' -f1 /proc/uptime)"
}
