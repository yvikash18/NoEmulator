#!/system/bin/sh
# Add packages to Android's ANGLE selection, and take them back out again.
#
# The selection is two global settings read at app start:
#
#   angle_gl_driver_selection_pkgs     com.a,com.b
#   angle_gl_driver_selection_values   angle,angle
#
# They are parallel lists matched by position, so neither can be edited without
# the other. Writing the package list directly is what v0.4.6 did, and it
# replaced whatever was there: a package the user had put on ANGLE for their own
# reasons was dropped for as long as NoEmulator was installed, and NoEmulator's
# own packages were left behind forever when it was removed (issue #25).
#
# Both entry points read the current pair, rebuild it, and write it back, so a
# package nobody here named is carried through untouched. A package we add gets
# the value 'angle'; a pre-existing one keeps whatever value it had, which may
# be 'default' or 'native'.
#
# Nothing outside the shell is used except tr -- no paste, cut, cmp or temp
# files. These functions run from service.sh and from the cleanup staged by
# uninstall.sh, where the shell resolves to busybox, and the module already pins
# toybox for stat because busybox's differs. A handful of package names does not
# need a tool, and uninstall.sh in particular runs while its own directory is
# being deleted, so it should not be writing scratch files into it.
#
# Sourced by service.sh, which adds, and by lib/angle_cleanup.sh, which removes.

NOEMULATOR_ANGLE_PKGS_KEY=angle_gl_driver_selection_pkgs
NOEMULATOR_ANGLE_VALUES_KEY=angle_gl_driver_selection_values

# A literal newline, for the IFS switches below. Written this way because `\n`
# is not portable through sh's quoting.
NOEMULATOR_ANGLE_NL='
'

# `settings` output goes to /dev/null, and that is load-bearing rather than
# tidiness. It wraps `cmd`, which hands its stdout and stderr to system_server
# over binder; a caller whose stdout is apply.log under /data/adb gives
# system_server a file it may not open and the whole transaction fails with
# "Failure calling service settings". Measured both ways: rc=2 against
# /data/adb, rc=0 against /dev/null (ADR 0015).
#
# `settings get` answers the literal string 'null' for a key never set, which is
# not a package list.
noemulator_angle_get() {
    angle_get=$(settings get global "$1" 2>/dev/null)
    [ "$angle_get" = "null" ] && angle_get=""
    echo "$angle_get"
}

# The current selection as one 'package value' line per entry.
#
# An entry missing either half is dropped. Nothing stops another writer leaving
# the two keys mismatched in length, and an entry whose value fell off has no
# meaning, because the value is what names the driver.
noemulator_angle_pairs() {
    angle_pairs_pkgs=$(noemulator_angle_get "$NOEMULATOR_ANGLE_PKGS_KEY" | tr ',' ' ')
    [ -n "$angle_pairs_pkgs" ] || return 0

    # The values become the positional parameters, so each can be consumed
    # alongside its package. The word splitting is the mechanism, not an
    # oversight: the values are a comma list turned into spaces, and quoting
    # would make the whole list one parameter.
    # shellcheck disable=SC2046
    set -- $(noemulator_angle_get "$NOEMULATOR_ANGLE_VALUES_KEY" | tr ',' ' ')

    for angle_pairs_pkg in $angle_pairs_pkgs; do
        [ "$#" -gt 0 ] || break
        [ -n "$1" ] && echo "$angle_pairs_pkg $1"
        shift
    done
}

# Does a 'package value' list already name this package?
#
# The leading newline makes every entry start with one, so the pattern cannot
# match a package that merely ends with the name being looked for.
noemulator_angle_lists_package() {
    case "$NOEMULATOR_ANGLE_NL$2" in
        *"$NOEMULATOR_ANGLE_NL$1 "*) return 0 ;;
    esac
    return 1
}

# Write a 'package value' list back as the two comma-separated settings.
#
# An empty list deletes both keys rather than writing empty strings, so a device
# that had no selection before NoEmulator has none after it.
noemulator_angle_write_pairs() {
    if [ -z "$1" ]; then
        settings delete global "$NOEMULATOR_ANGLE_PKGS_KEY" >/dev/null 2>&1
        settings delete global "$NOEMULATOR_ANGLE_VALUES_KEY" >/dev/null 2>&1
        return
    fi

    angle_write_pkgs=""
    angle_write_values=""

    angle_write_ifs="$IFS"
    IFS="$NOEMULATOR_ANGLE_NL"
    for angle_write_entry in $1; do
        IFS="$angle_write_ifs"
        angle_write_pkgs="${angle_write_pkgs:+$angle_write_pkgs,}${angle_write_entry%% *}"
        angle_write_values="${angle_write_values:+$angle_write_values,}${angle_write_entry##* }"
        IFS="$NOEMULATOR_ANGLE_NL"
    done
    IFS="$angle_write_ifs"

    settings put global "$NOEMULATOR_ANGLE_PKGS_KEY" "$angle_write_pkgs" >/dev/null 2>&1 &&
    settings put global "$NOEMULATOR_ANGLE_VALUES_KEY" "$angle_write_values" >/dev/null 2>&1
}

# Put each named package on ANGLE, keeping every package already there.
#
# Re-running is a no-op: a package already listed is not added again, so the
# setting does not grow by one entry per boot.
noemulator_angle_add() {
    [ -n "$1" ] || return 0

    angle_add_current=$(noemulator_angle_pairs)
    angle_add_next="$angle_add_current"

    for angle_add_pkg in $(printf '%s' "$1" | tr ',' ' '); do
        noemulator_angle_lists_package "$angle_add_pkg" "$angle_add_next" && continue
        angle_add_next="${angle_add_next:+$angle_add_next$NOEMULATOR_ANGLE_NL}$angle_add_pkg angle"
    done

    [ "$angle_add_current" = "$angle_add_next" ] && return 0
    noemulator_angle_write_pairs "$angle_add_next"
}

# Take each named package back off, leaving every other entry as it was.
noemulator_angle_remove() {
    [ -n "$1" ] || return 0

    angle_remove_ours=$(printf '%s' "$1" | tr ',' ' ')
    [ -n "$angle_remove_ours" ] || return 0

    angle_remove_current=$(noemulator_angle_pairs)
    angle_remove_next=""

    angle_remove_ifs="$IFS"
    IFS="$NOEMULATOR_ANGLE_NL"
    for angle_remove_entry in $angle_remove_current; do
        IFS="$angle_remove_ifs"
        angle_remove_keep=yes
        for angle_remove_our in $angle_remove_ours; do
            [ "${angle_remove_entry%% *}" = "$angle_remove_our" ] && angle_remove_keep=no
        done
        [ "$angle_remove_keep" = yes ] &&
            angle_remove_next="${angle_remove_next:+$angle_remove_next$NOEMULATOR_ANGLE_NL}$angle_remove_entry"
        IFS="$NOEMULATOR_ANGLE_NL"
    done
    IFS="$angle_remove_ifs"

    [ "$angle_remove_current" = "$angle_remove_next" ] && return 0
    noemulator_angle_write_pairs "$angle_remove_next"
}
