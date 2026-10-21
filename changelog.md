# Changelog

## v0.7.0

First public release.

- Hides the emulator from apps with SUSFS kernel rules: a coherent Pixel 8 build
  identity, emulator properties deleted, emulator device nodes and the gralloc mapper
  redirected to neutral names, the GPU driver presented as `mali`.
- WebUI in the KernelSU manager: Home (did the last boot work, failed rules, full log),
  ANGLE (hide the GL renderer per app), Options (Run ARM apps, Sync the host clipboard,
  Reboot now), About (version check, credits).
- The module card shows `✅ Working.` or `❌ Needs attention:` after each boot.
- Bug reports: **Action** or the Log page saves a redacted report to `/sdcard/Download`.
- Requires susfs4ksu-lkm-x64 v0.0.7 or later. Known limits: [LIMITATIONS.md](LIMITATIONS.md).
