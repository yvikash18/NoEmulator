#!/system/bin/sh
# The WebUI's shell half: everything the page needs, as plain lines.
#
# The page is a view. Every decision -- which packages exist, which are on
# ANGLE, which of those are ours, and how the config is edited -- happens here,
# because this file can be tested on a host with no device and the page cannot.
# `ksu.exec` runs each of these as root and hands the page back stdout.
#
# Output is one record per line, space-separated, never JSON. A shell that has
# to quote JSON correctly is a shell that will get it wrong on a package name
# with an unexpected character, and the page can split on spaces.
#
# Usage: angle_webui.sh <command> [package]
#
#   selection          one 'package value ours|theirs' line per entry in the
#                      live ANGLE selection
#   packages           one package name per line: installed, third-party
#   packages --all     the same, including system packages
#   add <package>      name it in the user config and put it on ANGLE now
#   adopt <package>    name it in the user config, leaving the live setting alone
#   remove <package>   take it out of both
#
# add and remove print nothing on success and exit non-zero with a message on
# stderr otherwise, so the page can show the reason rather than a blank failure.

set -eu

NOEMULATOR_WEBUI_DIR=${0%/*}
. "$NOEMULATOR_WEBUI_DIR/user_config.sh"
. "$NOEMULATOR_WEBUI_DIR/angle_settings.sh"
. "$NOEMULATOR_WEBUI_DIR/webui_config.sh"

# The same charset generate_rules.sh enforces. Checked here as well as there
# because this path writes the config rather than reading it: a name carrying a
# space or a quote would produce a line that the generator then rejects, and the
# module would stop applying every rule until someone hand-edited the file.
noemulator_webui_check_package() {
    case "$1" in
        *[!A-Za-z0-9._]*|'')
            echo "not a package name: $1" >&2
            return 1
            ;;
    esac
}

# Packages this module put on ANGLE, from the user config rather than from the
# live setting. The distinction is the point: a package the user put there for their
# own reasons must not be editable from here, the same way uninstall leaves it
# alone (issue #25).
noemulator_webui_ours() {
    [ -e "$NOEMULATOR_USER_CONFIG" ] || return 0
    while IFS= read -r webui_line || [ -n "$webui_line" ]; do
        case "$webui_line" in
            'angle '*) echo "${webui_line#angle }" ;;
        esac
    done < "$NOEMULATOR_USER_CONFIG"
}

# Does the config already name this package?
#
# Compared as strings rather than with `grep -qx`, for the reason the remove
# comment below gives: a package name contains dots, `.` matches any character
# in a basic regular expression, and `com.a.b` would therefore match a config
# line reading `com.a_b`. Both are legal package names, and the guard would
# silently skip the append for a package the config does not name.
#
# The joined-string `case` is the same shape as noemulator_angle_lists_package:
# a newline on each side so a name cannot match a longer one that ends with it.
noemulator_webui_names_package() {
    case "$NOEMULATOR_ANGLE_NL$2$NOEMULATOR_ANGLE_NL" in
        *"$NOEMULATOR_ANGLE_NL$1$NOEMULATOR_ANGLE_NL"*) return 0 ;;
    esac
    return 1
}

noemulator_webui_append_angle() {
    noemulator_webui_append_line "angle $1"
}

noemulator_webui_selection() {
    webui_ours=$(noemulator_webui_ours)
    noemulator_angle_pairs | while read -r webui_package webui_value; do
        webui_owner=theirs
        for webui_mine in $webui_ours; do
            [ "$webui_package" = "$webui_mine" ] && webui_owner=ours
        done
        echo "$webui_package $webui_value $webui_owner"
    done
}

noemulator_webui_packages() {
    if [ "${1:-}" = "--all" ]; then
        pm list packages
    else
        pm list packages -3
    fi | sed 's/^package://' | sort
}

# Append, never rewrite: one line is added at the end and nothing else in the
# user config is touched (ADR 0019).
noemulator_webui_add() {
    noemulator_webui_check_package "$1"

    # Config first, settings second, and the order is deliberate. If the settings
    # write fails the config is already ahead of the device, and service.sh
    # applies it on the next boot, so the state converges. The other order would
    # leave a package on ANGLE that nothing records and that uninstall, which
    # reads the config, would not take back off.
    if ! noemulator_webui_names_package "$1" "$(noemulator_webui_ours)"; then
        noemulator_webui_append_angle "$1"
    fi

    # Run unconditionally, including when the config already named the package.
    # The config and the live selection are separate state and can disagree: any
    # other writer of angle_gl_driver_selection_pkgs can drop our entry while the
    # config line stays, and the page would then show Off with no way back on.
    # noemulator_angle_add is itself idempotent, so a package already there
    # produces no write.
    noemulator_angle_add "$1"
}

# Take over an entry somebody else put on ANGLE, by recording it in the config
# and changing nothing on the device.
#
# Without this there is no way off the 'theirs' state from the phone: the page
# refuses to edit an entry it does not own, so an entry predating the module, or
# set with a bare `settings put`, could only be managed over adb.
#
# It is deliberately not the same as add. add puts a package on ANGLE; adopt
# claims one that is already there, which is why it must refuse a package that
# is not in the live selection -- recording a package the device is not running
# on ANGLE would make the config describe a state that does not exist, and the
# next boot would then create it.
#
# Adopting has a real consequence and the page says so before doing it: once the
# config names the package, uninstall takes it off ANGLE, which it would not
# have done otherwise (issue #25).
noemulator_webui_adopt() {
    noemulator_webui_check_package "$1"

    if noemulator_webui_names_package "$1" "$(noemulator_webui_ours)"; then
        return 0
    fi

    if ! noemulator_angle_lists_package "$1" "$(noemulator_angle_pairs)"; then
        echo "not on ANGLE, so there is nothing to adopt: $1" >&2
        return 1
    fi

    noemulator_webui_append_angle "$1"
}

noemulator_webui_remove() {
    noemulator_webui_check_package "$1"
    noemulator_webui_drop_line "angle $1"
    noemulator_angle_remove "$1"
}

case "${1:-}" in
    selection) noemulator_webui_selection ;;
    packages)  noemulator_webui_packages "${2:-}" ;;
    add)       noemulator_webui_add "${2:?usage: angle_webui.sh add <package>}" ;;
    adopt)     noemulator_webui_adopt "${2:?usage: angle_webui.sh adopt <package>}" ;;
    remove)    noemulator_webui_remove "${2:?usage: angle_webui.sh remove <package>}" ;;
    *)
        echo "usage: angle_webui.sh selection|packages [--all]|add <package>|adopt <package>|remove <package>" >&2
        exit 2
        ;;
esac
