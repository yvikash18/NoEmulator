# What NoEmulator does not hide

Measured on the reference device, a rooted Android 16 Pixel 9 x86_64 AVD. arm64 support
in this fork has not yet been measured end to end; architecture-specific skips are
logged in `apply.log`.

| Signal | Why it stays | What you can do |
|---|---|---|
| **GL renderer** says `Android Emulator OpenGL ES Translator` | The GL driver answers inside the app's own process | Put the app on ANGLE ([ANGLE.md](ANGLE.md)). ANGLE then says `llvmpipe`, and its shading language version always names ANGLE |
| **`ro.boot.qemu.virtiowifi`** readable early in boot | The emulated Wi-Fi needs it to start | Nothing. It is deleted once `wlan0` appears (9.3 s on the reference device, 30 s cap) |
| **Hardware is still the emulator architecture**: `uname()`, the ABI list, `/proc/cpuinfo` | Not spoofed. The build claims a Pixel 8 on hardware no Pixel 8 has | Nothing yet |
| **ARM translator**, when ARM apps are on (x86_64 AVDs) | It cannot be hidden while it runs | Off by default: ARM-only apps then fail with `UnsatisfiedLinkError`. Turn on **Run ARM apps** in the WebUI (or `native_bridge keep`) and reboot, and every app sees `ro.dalvik.vm.native.bridge` and `libndk_translation.so`; x86_64 AVDs also expose `x86_64` in ABI keys, `uname()` and the `libc.so` ELF header. Hiding it while it runs is planned |
| **Host clipboard sync** off | It needs `ro.boot.qemu`, which is deleted | Turn on **Sync the host clipboard** (or `boot_qemu keep`) and reboot. Apps then see `Build.IS_EMULATOR` as true |
| **Device name** back to `sdk_gphone64_x86_64` after a settings reset | Root cannot replace the default the system set | Reboot; the name is written again |
| **Root** | Out of scope: NoEmulator hides the emulator, not KernelSU or SUSFS | Use a root-hiding module |
| **Properties change for everyone**, `adb shell` included | The module edits the real property areas. Paths are redirected for apps only | Read `module/artifacts.conf` and your user config to know which values are real |
| **43 emulator-named properties** (65 without the module) | Mostly `init.svc.*` names, which init rewrites on every service state change | Nothing yet. Detectors that walk the whole property table, such as ACED, score them |
| **Emulator-named HAL files** in `/vendor/lib64/hw` (`vulkan.ranchu.so`, `mapper.ranchu.so`, audio, sensors) | Redirects change which file an app opens, not the directory listing | Nothing yet |
