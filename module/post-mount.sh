#!/system/bin/sh
# Apply the open-redirect rules, after the module's overlay is mounted and before
# zygote starts.
#
# This stage is the whole point. Measured on the target AVD: post-mount.sh runs at
# uptime 7.4s with sys.boot_completed unset, no zygote64 process, and
# /vendor/lib64/hw/mapper.zuma.so already served from the overlay. Both halves of
# the problem are satisfied only here.
#
# post-fs-data is too early: the overlay is not mounted, so a redirect naming a
# file inside it finds nothing and is skipped. v0.4.1 ran these at service time
# instead, which is too late: the rules landed 20 seconds after post-mount, and a
# detector that was already running had opened /dev/goldfish_pipe_dprctd under its
# real name. Its exported report still showed the artifact
# (analysis/baseline/duck_detector_report_Pixel_8_20261016_172119.txt).
#
# Running before boot completes means a bad rule can take the boot down, which is
# what happened in v0.4.0. Three things make that survivable: post-fs-data.sh's
# boot marker disables the module after a boot that never finished, every failure
# path below skips its rule rather than installing a broken one, and both the
# cloned nodes and the staged libraries have their SELinux label read back before
# any rule naming them is written.

MODDIR=${0%/*}
exec >>"$MODDIR/apply.log" 2>&1
echo "NoEmulator redirects $(date -u) uptime=$(cut -d' ' -f1 /proc/uptime)"

. "$MODDIR/lib/arch_support.sh"
NOEMULATOR_ARCH=$(noemulator_detect_arch)

SUSFS_REDIRECT_NODE=/proc/susfs_open_redirect

# stat is called as toybox explicitly. At this stage the shell resolves `stat` to
# busybox, whose stat has no %C: it printed the literal letter 'C', chcon rejected
# it, and the v0.4.0 nodes were left labelled u:object_r:device:s0 instead of
# qemu_device. Every non-su process then got EACCES and the boot never finished.
NOEMULATOR_STAT=/system/bin/toybox

# Redirect opens of one path to another, creating the replacement first if the
# target is a device node.
#
# Why a replacement rather than hiding: an app's own /proc/self/fd and
# /proc/self/maps name the goldfish nodes, and a detector greps those for
# 'goldfish', 'ranchu' and 'qemu'. Hiding them makes gfxstream's open fail inside
# every app process and crash-loops the device
# (docs/adr/0010-emulator-device-nodes-stay-visible.md). A redirect to a node with
# the same major and minor is the same device under another name, so nothing
# breaks and the path the app reads back is clean.
#
# The replacement is made here, from the target's own identity, rather than being
# listed in artifacts.conf: the numbers belong to the running kernel, not to a
# config file.
noemulator_redirect() {
    redirect_target="$1"
    redirect_replacement="$2"
    redirect_scheme="$3"

    if [ ! -e "$redirect_target" ]; then
        echo "redirect: no target $redirect_target on $NOEMULATOR_ARCH; skipped"
        return 0
    fi

    if [ ! -e "$redirect_replacement" ] && [ -c "$redirect_target" ]; then
        noemulator_clone_device_node "$redirect_target" "$redirect_replacement" || return 0
    fi

    if [ ! -e "$redirect_replacement" ]; then
        echo "redirect: no replacement $redirect_replacement on $NOEMULATOR_ARCH; skipped"
        return 0
    fi

    noemulator_labels_match "$redirect_target" "$redirect_replacement" || return 0

    # The node's verb is 'add_open_redirect', not 'add' as susfs_path uses
    # (susfs4ksu-lkm-x64 PROC_INTERFACES.en.md:107). A bare 'add' is refused.
    #
    # 'no_reverse' stops susfs rewriting the replacement's name back to the
    # target's for apps whose KernelSU "Umount modules" is on. That rewrite exists
    # to hide a redirect; here the replacement's name is the point. A susfs build
    # without the flag refuses the five-word line and registers nothing, so the
    # rule is written again without it, and the app must then have "Umount
    # modules" off (ADR 0014).
    if echo "add_open_redirect $redirect_target $redirect_replacement $redirect_scheme no_reverse" \
        > "$SUSFS_REDIRECT_NODE" 2>/dev/null; then
        :
    elif echo "add_open_redirect $redirect_target $redirect_replacement $redirect_scheme" \
        > "$SUSFS_REDIRECT_NODE"; then
        echo "redirect: susfs has no no_reverse; $redirect_target is only hidden from apps with Umount modules off"
    else
        echo "redirect: the node refused $redirect_target -> $redirect_replacement"
        return 0
    fi
    echo "redirect: $redirect_target -> $redirect_replacement (scheme $redirect_scheme)"
}

# Refuse a replacement an app may not open.
#
# The target is something every app process already opens, so its label is the
# label the replacement needs. v0.4.1 shipped both staged libraries labelled
# u:object_r:system_file:s0 instead of same_process_hal_file:s0, because the
# installer relocates $MODPATH/system/vendor and the label did not survive the
# move. A rule pointing at a file nothing may map is worse than no rule: the
# artifact stays visible either way, and the mismatch costs the app its mapping.
noemulator_labels_match() {
    match_target="$1"
    match_replacement="$2"

    match_target_label=$("$NOEMULATOR_STAT" stat -c '%C' "$match_target" 2>/dev/null)
    match_replacement_label=$("$NOEMULATOR_STAT" stat -c '%C' "$match_replacement" 2>/dev/null)

    [ "$match_target_label" = "$match_replacement_label" ] && return 0

    echo "redirect: $match_replacement is $match_replacement_label, not $match_target_label; skipped"
    return 1
}

# Make a second node for the same character device, indistinguishable from the
# first except in name.
noemulator_clone_device_node() {
    clone_target="$1"
    clone_replacement="$2"

    clone_context=$("$NOEMULATOR_STAT" stat -c '%C' "$clone_target" 2>/dev/null)
    case "$clone_context" in
        *:*:*:*) ;;
        *)
            echo "redirect: cannot read the SELinux label of $clone_target; skipped"
            return 1
            ;;
    esac

    clone_numbers=$("$NOEMULATOR_STAT" stat -c '%t %T' "$clone_target" 2>/dev/null)
    clone_major=$((0x${clone_numbers%% *})) || return 1
    clone_minor=$((0x${clone_numbers##* })) || return 1

    mknod "$clone_replacement" c "$clone_major" "$clone_minor" || {
        echo "redirect: mknod $clone_replacement failed; skipped"
        return 1
    }

    chmod "$("$NOEMULATOR_STAT" stat -c '%a' "$clone_target")" "$clone_replacement"
    chown "$("$NOEMULATOR_STAT" stat -c '%U:%G' "$clone_target")" "$clone_replacement"
    chcon "$clone_context" "$clone_replacement"

    # Read the label back rather than trusting chcon's exit status. An app that
    # was allowed the original and is denied the replacement is the whole failure.
    if [ "$("$NOEMULATOR_STAT" stat -c '%C' "$clone_replacement")" != "$clone_context" ]; then
        echo "redirect: $clone_replacement did not take the label $clone_context; removed"
        rm -f "$clone_replacement"
        return 1
    fi
    return 0
}

. "$MODDIR/lib/user_config.sh"
RULES="$(sh "$MODDIR/lib/generate_rules.sh" "$MODDIR/artifacts.conf" "$NOEMULATOR_USER_CONFIG")" || {
    echo "artifacts.conf or the user config is invalid; nothing applied"
    exit 1
}

# The late deletions go first, and deliberately before the open-redirect guard
# below. SUS_PATH and OPEN_REDIRECT are separately advertised susfs features
# (docs/re/REF_susfs4ksu_lkm_x64.md:137,144) and customize.sh accepts an install on
# SUS_PATH alone. Launching the waiter after the guard meant a kernel with one and
# not the other took the early exit and never deleted ro.boot.qemu.virtiowifi at
# all, while every other delprop still ran. The deletions need neither node.
#
# Through files rather than pipes: the appliers wait and must run in the
# background, and a backgrounded `while read` on a pipe would hold the pipe open
# behind it.
#
# One background job runs both waiters in turn. Each ends by rebuilding the
# property areas with `resetprop -c --force`, and running them one after the other
# keeps the two rebuilds from overlapping.
echo "$RULES" | grep '^noemulator_delprop_after_wifi ' > "$MODDIR/after_wifi.rules"
echo "$RULES" | grep '^noemulator_delprop_once_set ' > "$MODDIR/once_set.rules"
. "$MODDIR/lib/delete_after_wifi.sh"
. "$MODDIR/lib/delete_once_set.sh"
noemulator_late_deletions() {
    if [ -s "$MODDIR/after_wifi.rules" ]; then
        noemulator_delete_after_wifi "$MODDIR/after_wifi.rules"
    fi
    if [ -s "$MODDIR/once_set.rules" ]; then
        noemulator_delete_once_set "$MODDIR/once_set.rules"
    fi
    rm -f "$MODDIR/after_wifi.rules" "$MODDIR/once_set.rules"
}
noemulator_late_deletions &

if [ ! -e "$SUSFS_REDIRECT_NODE" ]; then
    echo "susfs open-redirect node absent; no redirects applied"
    exit 1
fi

echo "$RULES" | grep '^noemulator_redirect ' | while IFS= read -r rule; do
    eval "$rule" || echo "failed: $rule"
done

echo "redirects done"
