#!/system/bin/sh
# Shared architecture mapping for prerequisite selection.

noemulator_normalize_arch() {
    case "$1" in
        x64|x86_64) echo x64 ;;
        arm64|aarch64) echo arm64 ;;
        *) echo unknown ;;
    esac
}

noemulator_detect_arch() {
    if [ -n "${ARCH:-}" ]; then
        noemulator_normalize_arch "$ARCH"
        return
    fi
    noemulator_normalize_arch "$(uname -m 2>/dev/null)"
}

noemulator_susfs_module_id() {
    case "$1" in
        x64) echo susfs_lkm_x64 ;;
        arm64) echo susfs_lkm ;;
        *) return 1 ;;
    esac
}

noemulator_susfs_prerequisite() {
    case "$1" in
        x64) echo susfs4ksu-lkm-x64 ;;
        arm64) echo susfs4ksu-lkm ;;
        *) return 1 ;;
    esac
}
