//! byakugan's library: everything except the two entry points.
pub const model = @import("model.zig");
pub const mft = @import("mft.zig");
pub const scan = @import("scan.zig");
pub const folder_scan = @import("folder_scan.zig");
pub const volume = @import("volume.zig");
pub const treemap = @import("treemap.zig");
pub const tree_view = @import("tree_view.zig");
pub const theme = @import("theme.zig");
pub const demo = @import("demo.zig");

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
