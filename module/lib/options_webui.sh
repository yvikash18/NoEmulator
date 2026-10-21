#!/system/bin/sh
# The WebUI's shell half for the Home and Options pages, as angle_webui.sh is for
# the ANGLE page (ADR 0019): every decision here, plain 'key value' lines out.
#
# Usage: options_webui.sh <command>
#
#   status        'key value' lines: version, susfs, nomount, redirects,
#                 one 'stage <name> done|missing' per boot stage, failures.
#                 Read from the last boot's section of apply.log.
#   arm           'configured on|off': does the user config keep the native bridge?
#                 'running on|off': is ro.dalvik.vm.native.bridge set right now?
#   arm on|off    add or drop that directive; it takes effect at the next boot
#   clipboard     the same two lines for keeping ro.boot.qemu, which is what
#                 turns host clipboard sync on
#   clipboard on|off
#   health        'health ok|warn', then one 'detail <sentence>' line per reason.
#                 The page's status card and the module card both read it.
#   failures      the last boot's 'failed: ' lines, as written
#   log           the last boot's section of apply.log
#   export        write a redacted report for a bug report; prints its path
#   reboot        reboot the device
#
# on and off print nothing on success, and fail with a message on stderr. The
# page shows "Reboot to apply" while configured and running differ.

set -eu

NOEMULATOR_WEBUI_DIR=${0%/*}
NOEMULATOR_WEBUI_MODULE=${NOEMULATOR_WEBUI_MODULE:-$NOEMULATOR_WEBUI_DIR/..}
NOEMULATOR_WEBUI_MODULES_ROOT=${NOEMULATOR_WEBUI_MODULES_ROOT:-/data/adb/modules}
NOEMULATOR_WEBUI_SUSFS_NODE=${NOEMULATOR_WEBUI_SUSFS_NODE:-/proc/susfs_path}

. "$NOEMULATOR_WEBUI_DIR/user_config.sh"
. "$NOEMULATOR_WEBUI_DIR/webui_config.sh"

# Both off by default: keeping the bridge lets every app see it (ADR 0023), and
# keeping ro.boot.qemu lets every app see that this is an emulator (ADR 0024).
NOEMULATOR_WEBUI_ARM_LINE='native_bridge keep'
NOEMULATOR_WEBUI_CLIPBOARD_LINE='boot_qemu keep'

# The last boot's lines of apply.log. post-fs-data.sh opens each boot with a
# header reading 'NoEmulator <date>'; post-mount's header reads
# 'NoEmulator redirects <date>', which must not reset the section.
noemulator_webui_last_boot() {
    awk '/^NoEmulator / && !/^NoEmulator redirects / { section = "" }
         { section = section $0 "\n" }
         END { printf "%s", section }' "$NOEMULATOR_WEBUI_MODULE/apply.log" 2>/dev/null
}

noemulator_webui_stage() {
    if printf '%s' "$2" | grep -q "$3"; then
        echo "stage $1 done"
    else
        echo "stage $1 missing"
    fi
}

noemulator_webui_status() {
    echo "version $(sed -n 's/^version=//p' "$NOEMULATOR_WEBUI_MODULE/module.prop")"

    if [ -e "$NOEMULATOR_WEBUI_SUSFS_NODE" ]; then echo 'susfs yes'; else echo 'susfs no'; fi

    if [ -d "$NOEMULATOR_WEBUI_MODULES_ROOT/nomount" ] &&
        [ ! -f "$NOEMULATOR_WEBUI_MODULES_ROOT/nomount/disable" ]; then
        echo 'nomount yes'
    else
        echo 'nomount no'
    fi

    webui_boot=$(noemulator_webui_last_boot)
    echo "redirects $(printf '%s' "$webui_boot" | grep -c '^redirect: .* -> .* (scheme [0-4])$')"
    noemulator_webui_stage post-fs-data "$webui_boot" '^done$'
    noemulator_webui_stage post-mount "$webui_boot" '^redirects done$'
    noemulator_webui_stage after-wifi "$webui_boot" '^delprop_after_wifi done'
    noemulator_webui_stage once-set "$webui_boot" '^delprop_once_set done'
    echo "failures $(printf '%s' "$webui_boot" | grep -c '^failed: ')"
}

# One verdict for the Home card and the module card (lib/module_status.sh), so the
# two cannot disagree about what counts as working.
noemulator_webui_health() {
    health_status=$(noemulator_webui_status)
    # grep -c prints 0 and exits 1 when nothing matches, which set -e would end
    # the script on.
    health_missing=$(printf '%s\n' "$health_status" | grep -c '^stage .* missing$' || :)
    health_failures=$(printf '%s\n' "$health_status" | sed -n 's/^failures //p')
    health_redirects=$(printf '%s\n' "$health_status" | sed -n 's/^redirects //p')

    if printf '%s\n' "$health_status" | grep -qx 'susfs yes' &&
        [ "$health_missing" -eq 0 ] && [ "$health_failures" -eq 0 ]; then
        echo 'health ok'
        echo "detail Every stage ran on the last boot, $health_redirects redirects applied."
        return 0
    fi

    echo 'health warn'
    printf '%s\n' "$health_status" | grep -qx 'susfs yes' ||
        echo 'detail The susfs kernel module is not loaded.'
    [ "$health_missing" -eq 0 ] || echo "detail $health_missing stage(s) did not finish."
    [ "$health_failures" -eq 0 ] || echo "detail $health_failures rule(s) failed."
}

# Read in the switch's own terms, so 'running' is comparable with 'configured'.
# AOSP treats a bridge value of 0 as no bridge.
noemulator_webui_arm_running() {
    case "$(getprop ro.dalvik.vm.native.bridge)" in
        ''|0) echo off ;;
        *) echo on ;;
    esac
}

# Any value counts: the framework compares it with "1", but a detector scores
# the property being there at all.
noemulator_webui_clipboard_running() {
    if [ -n "$(getprop ro.boot.qemu)" ]; then echo on; else echo off; fi
}

# noemulator_webui_switch <name> <directive line> [on|off]. The running half is
# read by noemulator_webui_<name>_running.
noemulator_webui_switch() {
    case "${3:-}" in
        '')
            if noemulator_webui_has_line "$2"; then
                echo 'configured on'
            else
                echo 'configured off'
            fi
            echo "running $("noemulator_webui_$1_running")"
            ;;
        on)
            noemulator_webui_has_line "$2" || noemulator_webui_append_line "$2"
            ;;
        off)
            noemulator_webui_drop_line "$2"
            ;;
        *)
            echo "usage: options_webui.sh $1 [on|off]" >&2
            return 2
            ;;
    esac
}

case "${1:-}" in
    status)    noemulator_webui_status ;;
    health)    noemulator_webui_health ;;
    failures)  noemulator_webui_last_boot | grep '^failed: ' || true ;;
    log)       noemulator_webui_last_boot ;;
    export)    sh "$NOEMULATOR_WEBUI_DIR/collect_logs.sh" ;;
    reboot)    svc power reboot ;;
    arm)       noemulator_webui_switch arm "$NOEMULATOR_WEBUI_ARM_LINE" "${2:-}" ;;
    clipboard) noemulator_webui_switch clipboard "$NOEMULATOR_WEBUI_CLIPBOARD_LINE" "${2:-}" ;;
    *)
        echo "usage: options_webui.sh status|health|failures|log|export|reboot|arm|clipboard [on|off]" >&2
        exit 2
        ;;
esac
