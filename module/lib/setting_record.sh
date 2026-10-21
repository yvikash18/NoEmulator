#!/system/bin/sh
# Write settings rows named by 'setting' directives, and remember what they held.
#
# A settings row is outside anything resetprop can reach: Settings.Global
# device_name is copied from Build.MODEL once, at first boot, and nothing
# rewrites it (docs/research/settings-device-name.md). So the row itself is
# written, after boot, and the value it replaced is kept so uninstall can put it
# back (issue #28).
#
# One record file per key, outside the module tree so an in-place update does
# not lose it. It holds two lines:
#
#   original=<value at the first successful read, or null for unset>
#   written=<value this module last wrote>
#
# 'null' is what `settings get` prints for a key that is not set, and the CLI
# cannot tell that apart from a row holding the string 'null', so the record
# uses the same word for unset.
#
# Sourced by service.sh, which applies and restores keys dropped from the config,
# and by lib/setting_restore.sh, which restores everything after uninstall.

NOEMULATOR_SETTING_RECORD_DIR=${NOEMULATOR_SETTING_RECORD_DIR:-/data/adb/noemulator-settings}

# A literal newline, written this way because `\n` is not portable through sh's
# quoting.
NOEMULATOR_SETTING_NL='
'

# Print the row's current value, 'null' if unset. Non-zero when the read failed,
# which is not the same as unset: a failed read recorded as the original would
# have uninstall erase the row (docs/review/0003-triage.md, finding 3). A value
# with a newline in it fails too, because the record holds one value per line.
noemulator_setting_read() {
    setting_read=$(settings get "$1" "$2" 2>/dev/null) || return 1
    case "$setting_read" in
        ''|*"$NOEMULATOR_SETTING_NL"*) return 1 ;;
    esac
    echo "$setting_read"
}

# global and secure rows keep a stored default beside the value, and the
# 'default' form asks for both to be set (finding 11; system has no such form).
# It is honoured only where the default was not set by the system:
# SettingsState.update() replaces a system-set default only for a system caller,
# and shell and root never count as one. device_name's default is system-set, so
# it keeps the emulator name whatever is written here (measured on the reference
# AVD, docs/research/settings-device-name.md, finding 5). The form stays because
# it does work on a row the system never set, such as a key that was unset.
#
# Output goes to /dev/null, not to the caller's apply.log: `settings` hands its
# stdout to system_server over binder, which may not open a file under
# /data/adb, and the write then fails (ADR 0015).
noemulator_setting_put() {
    if [ "$1" = system ]; then
        settings put "$1" "$2" "$3" >/dev/null 2>&1
    else
        settings put "$1" "$2" "$3" default >/dev/null 2>&1
    fi
}

noemulator_setting_record_path() {
    echo "$NOEMULATOR_SETTING_RECORD_DIR/$1.$2"
}

# Replaced whole through a rename, so a power cut mid-write leaves the old record
# or the new one, never half of each.
noemulator_setting_record_save() {
    mkdir -p "$NOEMULATOR_SETTING_RECORD_DIR" && chmod 0700 "$NOEMULATOR_SETTING_RECORD_DIR" || return 1
    printf 'original=%s\nwritten=%s\n' "$2" "$3" > "$1.tmp" && mv "$1.tmp" "$1"
}

# Sets setting_original and setting_written from a record file.
noemulator_setting_record_load() {
    setting_original=""
    setting_written=""
    while IFS= read -r setting_line || [ -n "$setting_line" ]; do
        case "$setting_line" in
            original=*) setting_original=${setting_line#original=} ;;
            written=*) setting_written=${setting_line#written=} ;;
        esac
    done < "$1"
}

# noemulator_setting_write <namespace> <key> <original> <value>
#
# The record is saved before the row is written, never after. If the write fails
# the record says the row should hold the value while it still holds the
# original, and the next boot writes it again. The other order loses the
# original whenever the write lands but reports failure: the next boot would find
# no record and take the configured value for the original.
noemulator_setting_write() {
    noemulator_setting_record_save "$(noemulator_setting_record_path "$1" "$2")" "$3" "$4" || {
        echo "setting $1 $2: could not save the record; nothing written"
        return 1
    }
    noemulator_setting_put "$1" "$2" "$4" || {
        echo "setting $1 $2: could not write; retried next boot"
        return 1
    }
    echo "setting $1 $2: written"
}

# A key with no record: whatever it holds now is the original.
noemulator_setting_first() {
    if [ "$3" = "$4" ]; then
        noemulator_setting_record_save "$(noemulator_setting_record_path "$1" "$2")" "$3" "$4"
        echo "setting $1 $2: already the configured value"
        return
    fi
    noemulator_setting_write "$1" "$2" "$3" "$4"
}

# noemulator_setting <namespace> <key> <value>: the applier for one directive.
#
# The rule (issue #28 spec, "Apply rule"), from the row's current value:
#   no record                     record it as the original; write unless equal
#   current = written             ours; write again only if the config moved
#   current = original != written went back through a reset or a rename back;
#                                 write again
#   anything else                 the user chose it; leave it
noemulator_setting() {
    setting_current=$(noemulator_setting_read "$1" "$2") || {
        echo "setting $1 $2: could not read; retried next boot"
        return 0
    }
    setting_record=$(noemulator_setting_record_path "$1" "$2")
    if [ ! -f "$setting_record" ]; then
        noemulator_setting_first "$1" "$2" "$setting_current" "$3"
        return
    fi

    noemulator_setting_record_load "$setting_record"
    if [ "$setting_current" = "$setting_written" ] && [ "$setting_written" = "$3" ]; then
        echo "setting $1 $2: already ours"
    elif [ "$setting_current" = "$setting_written" ] || [ "$setting_current" = "$setting_original" ]; then
        noemulator_setting_write "$1" "$2" "$setting_original" "$3"
    else
        echo "setting $1 $2: left as the user's"
    fi
}

# noemulator_setting_restore <namespace> <key>
#
# Put back what the record says the row held, but only while the row still holds
# what this module wrote: anything else is a value the user chose after us, and
# restoring over it would undo their choice (finding 6). An unset original is
# deleted, never written as the string 'null' (finding 4). The record goes once
# the key needs nothing more; non-zero means try again next boot.
#
# A row recorded as already at the configured value was never written, so there
# is nothing to put back; writing the same value would only change the row's
# owner from android to root.
noemulator_setting_restore() {
    setting_record=$(noemulator_setting_record_path "$1" "$2")
    [ -f "$setting_record" ] || return 0
    setting_current=$(noemulator_setting_read "$1" "$2") || {
        echo "setting $1 $2: could not read; restore retried next boot"
        return 1
    }
    noemulator_setting_record_load "$setting_record"

    if [ "$setting_original" = "$setting_written" ]; then
        echo "setting $1 $2: never written; nothing to restore"
    elif [ "$setting_current" != "$setting_written" ]; then
        echo "setting $1 $2: left as the user's"
    else
        noemulator_setting_put_back "$1" "$2" "$setting_original" || return 1
    fi
    rm -f "$setting_record"
}

# noemulator_setting_put_back <namespace> <key> <original>
noemulator_setting_put_back() {
    if [ "$3" = null ]; then
        settings delete "$1" "$2" >/dev/null 2>&1 || {
            echo "setting $1 $2: could not delete; restore retried next boot"
            return 1
        }
        echo "setting $1 $2: deleted, as it was unset"
        return 0
    fi
    noemulator_setting_put "$1" "$2" "$3" || {
        echo "setting $1 $2: could not write; restore retried next boot"
        return 1
    }
    echo "setting $1 $2: restored"
}

# noemulator_setting_ids <generated rules>
#
# One 'namespace.key' line per setting rule: the names the record files carry.
# Parsed with builtins from the generator's fixed quoting,
# noemulator_setting 'ns' 'key' 'value'.
noemulator_setting_ids() {
    printf '%s\n' "$1" | while IFS= read -r setting_rule; do
        case "$setting_rule" in
            "noemulator_setting '"*) ;;
            *) continue ;;
        esac
        setting_rest=${setting_rule#"noemulator_setting '"}
        setting_namespace=${setting_rest%%"'"*}
        setting_rest=${setting_rest#*"' '"}
        echo "$setting_namespace.${setting_rest%%"'"*}"
    done
}

# noemulator_setting_restore_unconfigured <namespace.key lines>
#
# Restore every recorded key not in the list. service.sh passes the keys the
# config still sets, so a key a release stopped setting is undone rather than
# stranded (finding 5); the restorer passes nothing, because after uninstall no
# key is configured. Non-zero if any key has to be tried again.
noemulator_setting_restore_unconfigured() {
    setting_retry=0
    for setting_file in "$NOEMULATOR_SETTING_RECORD_DIR"/*; do
        [ -f "$setting_file" ] || continue
        setting_id=${setting_file##*/}
        case "$setting_id" in
            *.tmp) continue ;;
        esac
        case "$NOEMULATOR_SETTING_NL$1$NOEMULATOR_SETTING_NL" in
            *"$NOEMULATOR_SETTING_NL$setting_id$NOEMULATOR_SETTING_NL"*) continue ;;
        esac
        # The namespace has no dot and the key may, so the first dot splits them.
        noemulator_setting_restore "${setting_id%%.*}" "${setting_id#*.}" || setting_retry=1
    done
    # The directory goes with its last record, so a config that sets nothing
    # leaves no trace; rmdir refuses while any record is left.
    rmdir "$NOEMULATOR_SETTING_RECORD_DIR" 2>/dev/null
    return "$setting_retry"
}
