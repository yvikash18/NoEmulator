#!/system/bin/sh
# Apply the artifact rules, before zygote starts.
#
# This stage matters: the detector compares a snapshot taken at app startup against
# the main process, and deleting ro.dalvik.vm.native.bridge only stops the bridge
# loading if it happens before zygote reads it.

MODDIR=${0%/*}
exec >"$MODDIR/apply.log" 2>&1

echo "NoEmulator $(date -u)"

# Self-disable after a boot that never completed.
#
# v0.1.0 boot-looped a tester's device, and a module distributed to other people
# must not need a working adb to recover from that. service.sh clears this marker
# once sys.boot_completed is set, so finding it here means the previous boot
# applied these rules and never came up.
BOOT_MARKER="$MODDIR/booting"
if [ -f "$BOOT_MARKER" ]; then
    rm -f "$BOOT_MARKER"
    : > "$MODDIR/disable"
    echo "previous boot did not complete; NoEmulator disabled itself"
    sh "$MODDIR/lib/module_status.sh" "Disabled itself: the last boot did not complete. Re-enable it to try again."
    exit 1
fi
: > "$BOOT_MARKER"

# KernelSU runs each module's post-fs-data.sh in directory order, unsorted and one
# at a time (ksud module.rs, foreach_module), so the selected susfs_lkm loader may not
# have run yet. Measured 2026-10-20: after a reinstall of that module, this script
# ran first and applied nothing. Its loader is safe to run early: it does nothing
# when susfs is already up, and honours its own disable and remove flags.
. "$MODDIR/lib/arch_support.sh"
NOEMULATOR_ARCH=$(noemulator_detect_arch)
NOEMULATOR_SUSFS_MODULE=$(noemulator_susfs_module_id "$NOEMULATOR_ARCH" 2>/dev/null || :)

if [ -z "$NOEMULATOR_SUSFS_MODULE" ]; then
    echo "unsupported architecture: ${ARCH:-$NOEMULATOR_ARCH}; no rules applied"
    exit 1
fi

SUSFS_LOADER=/data/adb/modules/$NOEMULATOR_SUSFS_MODULE/post-fs-data.sh
if [ ! -e /proc/susfs_path ] && [ -f "$SUSFS_LOADER" ]; then
    echo "susfs not loaded yet; running its loader first"
    sh "$SUSFS_LOADER"
fi

if [ ! -e /proc/susfs_path ]; then
    echo "susfs not loaded from $SUSFS_LOADER; nothing applied"
    exit 1
fi

. "$MODDIR/lib/user_config.sh"
RULES="$(sh "$MODDIR/lib/generate_rules.sh" "$MODDIR/artifacts.conf" "$NOEMULATOR_USER_CONFIG")" || {
    echo "artifacts.conf or the user config is invalid; nothing applied"
    exit 1
}

# Each rule logs its own failure rather than aborting the run: a device node that
# is absent on this image should not stop the property rules being applied.
#
# The redirects are left to post-mount.sh. The module's /vendor overlay is not
# mounted yet at this stage, so a redirect naming a file inside it finds nothing
# and is skipped; measured, that is what made v0.4.0's mapper rule fail. By
# post-mount the overlay is up and zygote still does not exist.
echo "$RULES" | grep -v -e '^noemulator_redirect ' -e '^noemulator_angle ' \
    -e '^noemulator_delprop_after_wifi ' -e '^noemulator_delprop_once_set ' \
    -e '^noemulator_setting ' | while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    eval "$rule" || echo "failed: $rule"
done

# Deleting a property leaves its name orphaned in the raw property area. Rebuilding
# the areas removes that residue; measured in docs/research/spike-property-mechanism.md.
/data/adb/ksu/bin/resetprop -c --force

echo "done"
