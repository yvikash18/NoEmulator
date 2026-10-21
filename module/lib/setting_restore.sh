#!/system/bin/sh
# Put back the settings rows NoEmulator wrote, after the module itself is gone.
#
# The same problem lib/angle_cleanup.sh solves, for the 'setting' directive:
# ksud runs uninstall.sh at uptime 6.76s with no system_server, then deletes the
# module directory, so the restore has to outlive both. uninstall.sh copies this
# script and lib/setting_record.sh here, registers a hook that ksud runs on every
# boot, and starts a copy at once; whichever reaches the lock first does the work.
#
# Kept apart from the angle cleanup -- its own directory, hook and lock -- so a
# failure in one cannot hold the other's state hostage (issue #28 spec).
#
# What to restore comes from the record in NOEMULATOR_SETTING_RECORD_DIR, never
# from the config: it is right with the shipped config, with a config that no
# longer names the key, and with one that fails to parse (finding 2, finding 5).

NOEMULATOR_SETTING_RESTORE_DIR=${0%/*}
# Overridable so the suite can run this script on a host; the defaults are the
# only values used on a device.
NOEMULATOR_SETTING_RESTORE_HOOK=${NOEMULATOR_SETTING_RESTORE_HOOK:-/data/adb/service.d/noemulator-setting-restore.sh}

# The lock lives on /dev, a tmpfs, so a device powered off mid-wait does not come
# back with the lock still held and every later attempt locked out. mkdir is the
# lock because it is atomic.
NOEMULATOR_SETTING_RESTORE_LOCK=${NOEMULATOR_SETTING_RESTORE_LOCK:-/dev/noemulator-setting-restore.lock}

# Longer than any boot measured on the target (sys.boot_completed around 27s). A
# boot that never completes leaves everything staged, and the hook runs again.
NOEMULATOR_SETTING_RESTORE_TIMEOUT=180

. "$NOEMULATOR_SETTING_RESTORE_DIR/setting_record.sh"

noemulator_setting_restore_log() {
    echo "$(date) $*" >> "$NOEMULATOR_SETTING_RESTORE_DIR/restore.log"
}

# Everything staged for the restore, and the record it worked from. Called only
# once every key is done.
noemulator_setting_restore_finish() {
    rm -f "$NOEMULATOR_SETTING_RESTORE_HOOK"
    rm -rf "$NOEMULATOR_SETTING_RECORD_DIR" "$NOEMULATOR_SETTING_RESTORE_DIR"
}

noemulator_setting_restore_wait() {
    setting_restore_waited=0
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        [ "$setting_restore_waited" -lt "$NOEMULATOR_SETTING_RESTORE_TIMEOUT" ] || return 1
        setting_restore_waited=$((setting_restore_waited + 1))
        sleep 1
    done
}

# The lock is taken before the wait, not after it: both copies wait for the same
# boot, and two that both pass the wait would restore the same rows twice
# (finding 12).
noemulator_setting_restore_run() {
    mkdir "$NOEMULATOR_SETTING_RESTORE_LOCK" 2>/dev/null || return 0

    if ! noemulator_setting_restore_wait; then
        noemulator_setting_restore_log "timed out after ${NOEMULATOR_SETTING_RESTORE_TIMEOUT}s; the hook retries next boot"
    elif noemulator_setting_restore_unconfigured "" >> "$NOEMULATOR_SETTING_RESTORE_DIR/restore.log"; then
        noemulator_setting_restore_finish
    else
        noemulator_setting_restore_log "a key could not be restored; the hook retries next boot"
    fi
    rmdir "$NOEMULATOR_SETTING_RESTORE_LOCK"
}

noemulator_setting_restore_run
