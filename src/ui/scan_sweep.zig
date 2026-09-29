//! The scan line drawn over the preview while the scanner reads: where the
//! carriage is in the area being scanned, eased between the scanner's
//! percent updates (at 6400 dpi those arrive every few seconds).

const std = @import("std");
const PreviewSelection = @import("scan_workflow.zig").PreviewSelection;

pub const Sweep = struct {
    /// Preview-pixel area being read top to bottom; null for the whole
    /// preview (a preview scan).
    area: ?PreviewSelection,
    /// 0 at the top of the area, 1 at the bottom.
    fraction: f64,
    ir_pass: bool,
    /// No lines have arrived for this pass yet (setup and calibration).
    waiting: bool,
};

/// Moves the line at the rate percent updates have been arriving, never more
/// than one percent past the latest update and never backwards.
pub const Animator = struct {
    ir_pass: bool = false,
    first_percent: ?u8 = null,
    first_ms: u64 = 0,
    last_percent: u8 = 0,
    last_ms: u64 = 0,
    shown: f64 = 0.0,

    pub fn reset(self: *Animator) void {
        self.* = .{};
    }

    /// The line's position (0 to 1) for this frame, or null while the pass
    /// has not reported any progress.
    pub fn update(self: *Animator, percent: ?u8, ir_pass: bool, now_ms: u64) ?f64 {
        const reported = @min(percent orelse 0, 100);
        if (ir_pass != self.ir_pass or reported < self.last_percent) {
            self.* = .{ .ir_pass = ir_pass };
        }
        if (reported == 0) return null;

        if (self.first_percent == null) {
            self.first_percent = reported;
            self.first_ms = now_ms;
            self.last_percent = reported;
            self.last_ms = now_ms;
        } else if (reported != self.last_percent) {
            self.last_percent = reported;
            self.last_ms = now_ms;
        }

        var estimate: f64 = @floatFromInt(self.last_percent);
        const first = self.first_percent.?;
        if (self.last_percent > first and self.last_ms > self.first_ms) {
            const per_ms = @as(f64, @floatFromInt(self.last_percent - first)) /
                @as(f64, @floatFromInt(self.last_ms - self.first_ms));
            const ahead = per_ms * @as(f64, @floatFromInt(now_ms -| self.last_ms));
            estimate += @min(ahead, 1.0);
        }
        self.shown = @max(self.shown, @min(estimate / 100.0, 1.0));
        return self.shown;
    }
};

test "the scan line glides between percent updates without passing the next one" {
    var animator = Animator{};
    try std.testing.expectEqual(@as(?f64, null), animator.update(null, false, 0));
    try std.testing.expectEqual(@as(?f64, null), animator.update(0, false, 1000));

    try std.testing.expectApproxEqAbs(0.10, animator.update(10, false, 2000).?, 1e-9);
    // No rate yet: it holds.
    try std.testing.expectApproxEqAbs(0.10, animator.update(10, false, 5000).?, 1e-9);
    // 10 -> 12 took 4 s, half a percent per second.
    try std.testing.expectApproxEqAbs(0.12, animator.update(12, false, 6000).?, 1e-9);
    try std.testing.expectApproxEqAbs(0.1225, animator.update(12, false, 6500).?, 1e-9);
    // Capped one percent past the last update when the scanner stalls.
    try std.testing.expectApproxEqAbs(0.13, animator.update(12, false, 60000).?, 1e-9);
    // A late update never pulls the line back.
    try std.testing.expectApproxEqAbs(0.13, animator.update(13, false, 60001).?, 1e-9);
}

test "the scan line restarts for the IR pass" {
    var animator = Animator{};
    _ = animator.update(90, false, 1000);
    _ = animator.update(100, false, 2000);
    try std.testing.expectEqual(@as(?f64, null), animator.update(0, true, 3000));
    try std.testing.expectApproxEqAbs(0.05, animator.update(5, true, 4000).?, 1e-9);
}
