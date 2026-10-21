#!/usr/bin/env sh
# Turn artifacts.conf into the commands that apply it.
#
# Printing the commands rather than running them is what makes this testable on a
# host with no device, and it is also what `noemulator --dry-run` shows. Nothing
# here touches the device.
#
# Usage: generate_rules.sh <artifacts.conf> [user config]
# Writes one command per line to stdout. Exits non-zero on an unrecognised directive.
#
# The user config is read after the shipped list, in the same syntax and under the
# same checks, so a row it sets twice across the two files fails as it would in
# one. A user config that does not exist is no user config: the shipped list alone
# is what a device runs until the user makes a choice.

set -eu

SHIPPED_CONFIG="${1:?usage: generate_rules.sh <artifacts.conf> [user config]}"
USER_CONFIG="${2:-}"

# Rules go to the /proc nodes rather than through ksu_susfs, because the
# prerequisite publishes that CLI in its service.sh, which runs after
# post-fs-data. The nodes exist as soon as the kernel module is loaded.
# The node's verb is 'add', not the CLI's 'add_sus_path'
# (susfs4ksu-lkm-x64 PROC_INTERFACES.en.md:202). Writing the CLI spelling here
# returns EINVAL, which cost a boot to find.
SUSFS_PATH_NODE=/proc/susfs_path
SUSFS_KSTAT_NODE=/proc/susfs_kstat
RESETPROP=/data/adb/ksu/bin/resetprop

# The eleven stat fields after the inode, left as they are.
KSTAT_DEFAULTS=' default default default default default default default default default default default'

TAB=$(printf '\t')
NL='
'

# Every 'setting' namespace and key seen so far, one per line. A second line for
# the same row would have two values fight over it, and the record keeps one
# 'written' per row (docs/review/0003-triage.md, finding 9).
settings_seen=""

# Some deletes are the user's choice to skip, so they are held back until both
# files are read: the 'keep' directive may come after them, in the user config.
# One '<group> <command>' line per held delete, and one line per kept group.
# ARM translation is one group (docs/adr/0023-the-native-bridge-is-a-user-choice.md),
# the host clipboard another (docs/adr/0024-keeping-ro-boot-qemu-is-a-user-choice.md).
held_deletes=""
kept_groups=""

# generate_from <config>. The name is copied before the loop: the redirect branch
# reuses the positional parameters to split its argument.
generate_from() {
    CONFIG=$1
    [ -r "$CONFIG" ] || { echo "cannot read $CONFIG" >&2; exit 1; }

    line_number=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))

        # Trim surrounding whitespace before anything else: a line of spaces is blank,
        # and an indented directive is still a directive.
        #
        # Done with builtins, not sed. This script runs at post-fs-data, where forking
        # toybox sed once per line segfaulted on the target; a generator that forks per
        # line would be wasteful even where it works.
        while :; do
            case $line in
                ' '*|"$TAB"*) line=${line#?} ;;
                *) break ;;
            esac
        done
        while :; do
            case $line in
                *' '|*"$TAB") line=${line%?} ;;
                *) break ;;
            esac
        done

        case "$line" in
            ''|'#'*) continue ;;
        esac

        directive=${line%% *}
        argument=${line#* }

        if [ "$directive" = "$argument" ]; then
            echo "$CONFIG:$line_number: '$directive' needs an argument" >&2
            exit 1
        fi

        case "$directive" in
            hide)
                echo "echo 'add $argument' > $SUSFS_PATH_NODE"
                ;;
            kstat_inode)
                # 'kstat_inode <path> <inode>'. Apps that stat the path read this inode;
                # the other eleven stat fields stay live ('default'), so the mtime still
                # moves as files come and go. The node takes the same twelve fields as
                # the CLI (susfs4ksu-lkm-x64 kernel/susfs_kstat.c, parse_override).
                kstat_path=${argument%% *}
                kstat_inode=${argument#* }
                case "$kstat_path" in
                    /*) ;;
                    *)
                        echo "$CONFIG:$line_number: kstat_inode needs an absolute path, not '$kstat_path'" >&2
                        exit 1
                        ;;
                esac
                case "$kstat_path" in
                    *[!A-Za-z0-9._/-]*)
                        echo "$CONFIG:$line_number: '$kstat_path' is not a plain path" >&2
                        exit 1
                        ;;
                esac
                case "$kstat_inode" in
                    *[!0-9]*|''|0)
                        echo "$CONFIG:$line_number: kstat_inode needs <path> <inode>, an inode above 0" >&2
                        exit 1
                        ;;
                esac
                echo "echo 'add_sus_kstat_statically $kstat_path $kstat_inode$KSTAT_DEFAULTS' > $SUSFS_KSTAT_NODE"
                ;;
            redirect)
                # 'redirect <target> <replacement> <uid_scheme>'. The work of making
                # sure the replacement exists belongs to the applier, not here: this
                # script runs on a host with no device. It emits a call to the helper
                # post-fs-data.sh defines, which refuses to write a rule whose
                # replacement is missing -- an open redirected at nothing is ENOENT,
                # and ENOENT on a device node is what boot-looped v0.1.0
                # (docs/adr/0010-emulator-device-nodes-stay-visible.md).
                set -- $argument
                if [ "$#" -ne 3 ]; then
                    echo "$CONFIG:$line_number: 'redirect' needs <target> <replacement> <uid_scheme>" >&2
                    exit 1
                fi
                case "$3" in
                    [0-4]) ;;
                    *)
                        echo "$CONFIG:$line_number: uid_scheme must be 0-4, not '$3'" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_redirect '$1' '$2' '$3'"
                ;;
            angle)
                # 'angle <package>'. Runs the named package on ANGLE instead of the
                # emulator's GL driver, so glGetString reports no emulator token.
                # Applied from service.sh, not post-mount: `settings` talks to a
                # system service that does not exist before boot completes.
                #
                # One package per line. The applier accumulates them, because the two
                # settings keys are comma-separated lists and writing one package would
                # drop the rest.
                case "$argument" in
                    *[!A-Za-z0-9._]*|'')
                        echo "$CONFIG:$line_number: '$argument' is not a package name" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_angle '$argument'"
                ;;
            delprop)
                keep_group=""
                case "$argument" in
                    ro.dalvik.vm.native.bridge|ro.enable.native.bridge.exec) keep_group=native_bridge ;;
                    ro.boot.qemu) keep_group=boot_qemu ;;
                esac
                if [ -n "$keep_group" ]; then
                    held_deletes="$held_deletes$keep_group $RESETPROP -d $argument$NL"
                else
                    echo "$RESETPROP -d $argument"
                fi
                ;;
            native_bridge|boot_qemu)
                # '<group> keep'. The only value: a typo must not silently mean
                # "hide", or the user loses what they turned the switch on for.
                if [ "$argument" != keep ]; then
                    echo "$CONFIG:$line_number: $directive takes only 'keep', not '$argument'" >&2
                    exit 1
                fi
                kept_groups="$kept_groups$directive$NL"
                ;;
            delprop_after_wifi)
                # 'delprop_after_wifi <property>'. Deleted once wlan0 exists, not at
                # post-fs-data. The emulated Wi-Fi reads ro.boot.qemu.virtiowifi when
                # its HAL starts at 8.5s; deleting it at 5s leaves the AVD with no
                # wlan0 at all, which is both a lost feature and a contradiction a
                # detector scores (docs/adr/0016-delete-the-wifi-property-late.md).
                case "$argument" in
                    *[!A-Za-z0-9._-]*|'')
                        echo "$CONFIG:$line_number: '$argument' is not a property name" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_delprop_after_wifi '$argument'"
                ;;
            delprop_once_set)
                # 'delprop_once_set <property>'. For a property a vendor service sets
                # after post-fs-data, where a plain delprop finds nothing to delete.
                # Waits for it to be set, gives its readers time to read it, then
                # deletes (docs/adr/0020-delete-vendor-qemu-properties-once-set.md).
                case "$argument" in
                    *[!A-Za-z0-9._-]*|'')
                        echo "$CONFIG:$line_number: '$argument' is not a property name" >&2
                        exit 1
                        ;;
                esac
                echo "noemulator_delprop_once_set '$argument'"
                ;;
            setting)
                # 'setting <namespace> <key> <value>'. Writes a settings row after boot
                # and records what it replaced; lib/setting_record.sh is the applier.
                # The value is the rest of the line, spaces included, quoted the same
                # way setprop's is.
                namespace=${argument%% *}
                key_value=${argument#* }
                key=${key_value%% *}
                value=${key_value#* }
                if [ "$namespace" = "$key_value" ] || [ "$key" = "$value" ]; then
                    echo "$CONFIG:$line_number: 'setting' needs <namespace> <key> <value>" >&2
                    exit 1
                fi
                case "$namespace" in
                    global|secure|system) ;;
                    *)
                        echo "$CONFIG:$line_number: namespace must be global, secure or system, not '$namespace'" >&2
                        exit 1
                        ;;
                esac
                case "$key" in
                    *[!A-Za-z0-9_.]*|'')
                        echo "$CONFIG:$line_number: '$key' is not a settings key" >&2
                        exit 1
                        ;;
                esac
                case "$value" in
                    *\'*)
                        echo "$CONFIG:$line_number: a value may not contain a single quote" >&2
                        exit 1
                        ;;
                esac
                case "$NL$settings_seen" in
                    *"$NL$namespace $key$NL"*)
                        echo "$CONFIG:$line_number: 'setting $namespace $key' is set twice" >&2
                        exit 1
                        ;;
                esac
                settings_seen="$settings_seen$namespace $key$NL"
                echo "noemulator_setting '$namespace' '$key' '$value'"
                ;;
            setprop)
                name=${argument%% *}
                value=${argument#* }
                if [ "$name" = "$value" ]; then
                    echo "$CONFIG:$line_number: 'setprop $name' needs a value" >&2
                    exit 1
                fi
                # The emitted command is eval'd, and a value may contain a space
                # (ro.product.model=Pixel 8), so it is single-quoted. A value carrying a
                # single quote would break out of that quoting; no property needs one.
                case "$value" in
                    *\'*)
                        echo "$CONFIG:$line_number: a value may not contain a single quote" >&2
                        exit 1
                        ;;
                esac
                echo "$RESETPROP $name '$value'"
                ;;
            *)
                echo "$CONFIG:$line_number: unknown directive '$directive'" >&2
                exit 1
                ;;
        esac
    done < "$CONFIG"
}

generate_from "$SHIPPED_CONFIG"
if [ -n "$USER_CONFIG" ] && [ -e "$USER_CONFIG" ]; then
    generate_from "$USER_CONFIG"
fi
while IFS=' ' read -r group delete_command; do
    [ -n "$group" ] || continue
    case "$NL$kept_groups" in
        *"$NL$group$NL"*) ;;
        *) echo "$delete_command" ;;
    esac
done <<HELD
$held_deletes
HELD
