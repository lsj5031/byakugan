//! App-owned static Recursive Sans Linear faces. Register on the UI thread
//! before creating the app/windows; embedded bytes live for the process.
const ui = @import("nanoui").ui;

pub const family: []const u8 = "Recursive Sans Linear Static";

const faces = [_][]const u8{
    @embedFile("fonts/RecursiveSansLnrSt-Regular.ttf"),
    @embedFile("fonts/RecursiveSansLnrSt-Med.ttf"),
    @embedFile("fonts/RecursiveSansLnrSt-SemiBold.ttf"),
};
var registered: usize = 0;

/// Idempotent on the UI thread, including after a partial failure.
pub fn register() error{FontRegistrationFailed}!void {
    while (registered < faces.len) : (registered += 1) {
        if (!ui.registerFont(faces[registered])) return error.FontRegistrationFailed;
    }
}
