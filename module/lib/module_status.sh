#!/system/bin/sh
# Put a working or failed flag at the front of the module's description, which
# the KernelSU-Next manager shows on the module card.
#
# Usage: module_status.sh            the verdict of options_webui.sh health
#        module_status.sh <text>     <text> as the flag, for a stage that stops
#                                    before there is anything to judge
#
# Written with `ksud module config set --temp override.description`, which the
# manager shows in place of module.prop's description and forgets at the next
# boot. module.prop itself is never edited, so a flag can never outlive the boot
# it describes.
# ksud refuses the command outside a module's context; KSU_MODULE gives it one.

STATUS_DIR=${0%/*}
STATUS_KSUD=${NOEMULATOR_STATUS_KSUD:-/data/adb/ksud}

noemulator_status_flag() {
    [ $# -eq 0 ] || { echo "❌ $1"; return 0; }

    status_health=$(sh "$STATUS_DIR/options_webui.sh" health)
    if printf '%s\n' "$status_health" | grep -qx 'health ok'; then
        echo "✅ Working."
    else
        status_details=$(printf '%s\n' "$status_health" | sed -n 's/^detail //p' | tr '\n' ' ')
        echo "❌ Needs attention: ${status_details% } Open the WebUI for details."
    fi
}

status_text="$(noemulator_status_flag "$@") $(sed -n 's/^description=//p' "$STATUS_DIR/../module.prop")"
KSU_MODULE=noemulator "$STATUS_KSUD" module config set --temp override.description "$status_text" ||
    echo "status: ksud refused the module card description"
echo "status: $status_text"
