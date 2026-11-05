# Pinned nanoui Windows integration

The app uses the sibling path `../nanoui` from `build.zig.zon`.
Base: https://github.com/lsj5031/nanoui/commit/7d4424b1046f8bbab365b42f61d00f1934d4dcc8

Apply `nanoui-windows.patch` once to that exact revision, in a fresh checkout.
The README gives the complete clone/build commands. The patch contains:

- Native folder selection using IFileOpenDialog.
- Windows Animation effects preference propagation, including runtime changes.
- Reduced-motion widget interpolation and press-position corrections.
- The frame helper extracted to keep framework source files bounded.
- The associated widget and hidden Windows regression tests.

This preserves the existing local dependency interface without publishing or
overwriting an independently modified framework checkout. No nanoui Git metadata,
local ignore rules, build outputs or credentials are included.

The release check builds Byakugan with a separate clean clone of this base plus
only this patch, and runs the app's aggregate tests. It does not claim all of
nanoui's cross-platform targets were tested. When these changes are upstreamed,
update the pin and remove the superseded patch together.
