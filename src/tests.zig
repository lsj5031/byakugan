//! Pure tests: run this file as the test root so every local suite is
//! registered. The window suite has its own root because it imports nanoui.
test {
    _ = @import("mft.zig");
    _ = @import("model.zig");
    _ = @import("scan.zig");
    _ = @import("folder_scan.zig");
    _ = @import("treemap.zig");
    _ = @import("tree_view.zig");
    _ = @import("demo.zig");
    _ = @import("volume.zig");
}
