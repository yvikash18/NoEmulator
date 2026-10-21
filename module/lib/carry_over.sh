#!/system/bin/sh
# Move the choices an older version saved in artifacts.conf into the user config.
#
# Before versionCode 17 the WebUI wrote its lines into the module's own
# artifacts.conf, and an update replaces that file. Run by the installer: it
# compares the installed copy with the one being installed and carries over what
# only the installed copy has.
#
# Only `angle` and `delprop_once_set` lines are carried, the two kinds the WebUI
# wrote. Any other line found only in the installed copy is a hand edit, and it is
# named rather than copied: the user decides whether it belongs in the user config.
#
# Once only. An installed module at versionCode 17 or later already keeps choices
# in the user config, so a line only its copy has is a shipped rule the new
# version dropped, and carrying it would bring the rule back.
#
# Usage: carry_over.sh <installed module dir> <new artifacts.conf>
# Prints 'carried <line>' for each line added to the user config and
# 'not carried <line>' for each one left out.

set -eu

NOEMULATOR_CARRY_DIR=${0%/*}
. "$NOEMULATOR_CARRY_DIR/user_config.sh"
. "$NOEMULATOR_CARRY_DIR/webui_config.sh"

NOEMULATOR_CARRY_FIRST_VERSION=17

carry_installed="${1:?usage: carry_over.sh <installed module dir> <new artifacts.conf>}"
carry_shipped="${2:?usage: carry_over.sh <installed module dir> <new artifacts.conf>}"

[ -r "$carry_installed/artifacts.conf" ] || exit 0
carry_version=$(sed -n 's/^versionCode=//p' "$carry_installed/module.prop" 2>/dev/null)
case "$carry_version" in
    ''|*[!0-9]*) ;;
    *) [ "$carry_version" -lt "$NOEMULATOR_CARRY_FIRST_VERSION" ] || exit 0 ;;
esac

TAB=$(printf '\t')
NL='
'

# The directive lines of a config, trimmed the way generate_rules.sh trims them,
# one per line. Comments and blank lines are not choices.
carry_directives() {
    while IFS= read -r carry_line || [ -n "$carry_line" ]; do
        while :; do
            case $carry_line in
                ' '*|"$TAB"*) carry_line=${carry_line#?} ;;
                *) break ;;
            esac
        done
        while :; do
            case $carry_line in
                *' '|*"$TAB") carry_line=${carry_line%?} ;;
                *) break ;;
            esac
        done
        case "$carry_line" in
            ''|'#'*) ;;
            *) echo "$carry_line" ;;
        esac
    done < "$1"
}

carry_shipped_lines="$NL$(carry_directives "$carry_shipped")$NL"

carry_directives "$carry_installed/artifacts.conf" | while IFS= read -r carry_line; do
    case "$carry_shipped_lines" in
        *"$NL$carry_line$NL"*) continue ;;
    esac
    case "$carry_line" in
        'angle '*|'delprop_once_set '*)
            noemulator_webui_has_line "$carry_line" && continue
            noemulator_webui_append_line "$carry_line"
            echo "carried $carry_line"
            ;;
        *)
            echo "not carried $carry_line"
            ;;
    esac
done
