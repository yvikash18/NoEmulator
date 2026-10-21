#!/system/bin/sh
# Take NoEmulator's packages back off ANGLE, after the module itself is gone.
#
# Staged outside the module tree by uninstall.sh, because uninstall.sh cannot do
# this work itself. Measured on the target: ksud runs uninstall.sh at uptime
# 6.76s with sys.boot_completed unset, and deletes the module directory straight
# afterwards. `settings` is a client of system_server, which does not exist that
# early -- `settings get` answered rc=20 there. So the removal has to outlive
# both the script that knows about it and the directory it came from.
#
# Same shape as lib/delete_after_wifi.sh, which waits for wlan0 rather than for
# the framework, for the same reason: the work is cheap but cannot be done at
# the stage that knows it is needed.
#
# Run twice over, by design. uninstall.sh launches it in the background on the
# boot that removes the module, so the setting is usually corrected within the
# minute. It is also registered in /data/adb/service.d, which ksud runs on every
# boot, so a device that was powered off mid-wait still gets it. Whichever gets
# there first takes the lock; the loser exits.
#
# The package list is written in by uninstall.sh while artifacts.conf is still
# readable. Nothing here reads the module tree, which no longer exists.

NOEMULATOR_ANGLE_CLEANUP_DIR=${0%/*}
# Overridable so the suite can run this script on a host; the defaults are the
# only values used on a device.
NOEMULATOR_ANGLE_CLEANUP_HOOK=${NOEMULATOR_ANGLE_CLEANUP_HOOK:-/data/adb/service.d/noemulator-angle-cleanup.sh}

# mkdir is the lock because it is atomic: the background copy and the service.d
# copy race on the same boot and only one may edit the setting. It lives on
# /dev, a tmpfs, because a lock inside the staged directory survived a reboot: a
# device powered off mid-wait came back with it held, and every later boot's
# copy found it taken and gave up, leaving the packages on ANGLE for good
# (issue #47).
NOEMULATOR_ANGLE_CLEANUP_LOCK=${NOEMULATOR_ANGLE_CLEANUP_LOCK:-/dev/noemulator-angle-cleanup.lock}

# Longer than any boot measured on the target, where sys.boot_completed is set
# around 27s. A boot that never completes leaves the staged files in place and
# the hook runs again next time, which is why nothing is deleted on this path.
NOEMULATOR_ANGLE_CLEANUP_TIMEOUT=180

. "$NOEMULATOR_ANGLE_CLEANUP_DIR/angle_settings.sh"

noemulator_angle_cleanup_log() {
    echo "$(date) $*" >> "$NOEMULATOR_ANGLE_CLEANUP_DIR/cleanup.log"
}

# Everything this slice staged, and nothing else. Called only after the setting
# has actually been corrected.
noemulator_angle_cleanup_finish() {
    rm -f "$NOEMULATOR_ANGLE_CLEANUP_HOOK"
    rm -rf "$NOEMULATOR_ANGLE_CLEANUP_DIR"
}

noemulator_angle_cleanup_wait() {
    angle_cleanup_waited=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        [ "$angle_cleanup_waited" -lt "$NOEMULATOR_ANGLE_CLEANUP_TIMEOUT" ] || return 1
        angle_cleanup_waited=$((angle_cleanup_waited + 1))
        sleep 1
    done
    return 0
}

noemulator_angle_cleanup_locked() {
    angle_cleanup_packages=$(cat "$NOEMULATOR_ANGLE_CLEANUP_DIR/packages" 2>/dev/null)
    if [ -z "$angle_cleanup_packages" ]; then
        noemulator_angle_cleanup_finish
        return 0
    fi

    if ! noemulator_angle_cleanup_wait; then
        noemulator_angle_cleanup_log "timed out after ${NOEMULATOR_ANGLE_CLEANUP_TIMEOUT}s; the hook retries next boot"
        return 1
    fi

    if noemulator_angle_remove "$angle_cleanup_packages"; then
        noemulator_angle_cleanup_finish
        return 0
    fi

    noemulator_angle_cleanup_log "settings write failed; the hook retries next boot"
    return 1
}

noemulator_angle_cleanup_run() {
    mkdir "$NOEMULATOR_ANGLE_CLEANUP_LOCK" 2>/dev/null || return 0
    noemulator_angle_cleanup_locked
    angle_cleanup_status=$?
    rmdir "$NOEMULATOR_ANGLE_CLEANUP_LOCK"
    return "$angle_cleanup_status"
}

noemulator_angle_cleanup_run
