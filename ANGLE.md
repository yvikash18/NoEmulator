# ANGLE: hiding the GL renderer per app

By default an app's `glGetString` reports `Android Emulator OpenGL ES Translator`.
ANGLE, Android's own GL-over-Vulkan driver, reports no emulator token. It is per app
because putting every app on ANGLE changes how they render.

**From the phone:** open NoEmulator in the KernelSU manager, ANGLE tab, tick the app. It
applies at once; an app already running keeps its driver until restarted. The choice is
saved in the user config, so updates keep it and uninstall removes it.

A package you put on ANGLE yourself is never taken off. **Adopt** hands it to the module
without changing anything on the device.

**Renderer string (optional, by hand).** On ANGLE an app sees `llvmpipe`. To report a GPU
instead, add to `/data/adb/noemulator-user.conf` and reboot. These apply to every app on
ANGLE. No values ship: no verified renderer string for the Pixel 8's GPU was found.

```
setprop debug.angle.gl_vendor   ARM
setprop debug.angle.gl_renderer <a renderer string for the GPU you claim>
setprop debug.angle.gl_version  OpenGL ES 3.1 <a driver version for that GPU>
```

Keep `gl_version` at OpenGL ES 3.1: the shading language version reads
`OpenGL ES GLSL ES 3.10` and cannot be changed.

**From a shell:**

```sh
cd /data/adb/modules/noemulator
sh lib/angle_webui.sh add com.example.app      # or: adopt, remove
sh lib/angle_webui.sh selection                # what is on ANGLE, ours|theirs
```
