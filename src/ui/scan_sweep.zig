//! The scan line drawn over the preview while the scanner reads: where the
//! carriage is in the area being scanned, eased between the scanner's
//! percent updates (at 6400 dpi those arrive every few seconds, and the IR
//! pass delivers them in bursts).

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

/// Moves the line at the rate progress has been arriving. Between updates it
/// runs ahead by as much as the longest gap so far would cover (1 to 5
/// percent), so bursts of several percent after a pause do not stall it and
/// then snap it forward; it eases toward new reports and never moves back.
pub const Animator = struct {
    ir_pass: bool = false,
    first_percent: ?u8 = null,
    first_ms: u64 = 0,
    last_percent: u8 = 0,
    last_ms: u64 = 0,
    longest_gap_ms: u64 = 0,
    frame_ms: u64 = 0,
    /// Percent.
    shown: f64 = 0.0,

    const min_ahead = 1.0;
    const max_ahead = 5.0;
    const ease_ms = 600.0;

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

        const first = self.first_percent orelse {
            self.first_percent = reported;
            self.first_ms = now_ms;
            self.last_percent = reported;
            self.last_ms = now_ms;
            self.frame_ms = now_ms;
            self.shown = @floatFromInt(reported);
            return self.shown / 100.0;
        };
        if (reported != self.last_percent) {
            self.longest_gap_ms = @max(self.longest_gap_ms, now_ms -| self.last_ms);
            self.last_percent = reported;
            self.last_ms = now_ms;
        }

        var target: f64 = @floatFromInt(self.last_percent);
        if (self.last_percent > first and self.last_ms > self.first_ms) {
            const per_ms = @as(f64, @floatFromInt(self.last_percent - first)) /
                @as(f64, @floatFromInt(self.last_ms - self.first_ms));
            const ahead = std.math.clamp(per_ms * @as(f64, @floatFromInt(self.longest_gap_ms)), min_ahead, max_ahead);
            target += @min(per_ms * @as(f64, @floatFromInt(now_ms -| self.last_ms)), ahead);
        }
        target = @min(target, 100.0);

        const dt: f64 = @floatFromInt(now_ms -| self.frame_ms);
        self.frame_ms = now_ms;
        if (target > self.shown) self.shown += (target - self.shown) * (1.0 - @exp(-dt / ease_ms));
        return self.shown / 100.0;
    }
};

/// Runs the animator at 60 frames per second over `duration_ms`, feeding it
/// `percentAt(ms)`, and returns the largest single-frame step (percent) after
/// `settle_ms` and the final position.
fn simulate(animator: *Animator, percentAt: *const fn (u64) u8, duration_ms: u64, settle_ms: u64) struct { max_step: f64, last: f64, backwards: bool } {
    var previous: ?f64 = null;
    var max_step: f64 = 0.0;
    var backwards = false;
    var now: u64 = 0;
    while (now <= duration_ms) : (now += 16) {
        const shown = (animator.update(percentAt(now), false, now) orelse continue) * 100.0;
        if (previous) |before| {
            if (shown < before) backwards = true;
            if (now >= settle_ms) max_step = @max(max_step, shown - before);
        }
        previous = shown;
    }
    return .{ .max_step = max_step, .last = previous orelse 0.0, .backwards = backwards };
}

fn steadyPercent(ms: u64) u8 {
    // 1% every 6 s (RGB at 6400 dpi).
    return @intCast(@min(100, 1 + ms / 6000));
}

fn burstyPercent(ms: u64) u8 {
    // 4% at once every 8 s: the same 0.5%/s, delivered in bursts.
    return @intCast(@min(100, 4 + 4 * (ms / 8000)));
}

test "the scan line moves smoothly on steady and bursty progress" {
    var steady = Animator{};
    const s = simulate(&steady, &steadyPercent, 120_000, 13_000);
    try std.testing.expect(!s.backwards);
    try std.testing.expect(s.max_step < 0.02);
    try std.testing.expectApproxEqAbs(21.0, s.last, 1.5);

    var bursty = Animator{};
    const b = simulate(&bursty, &burstyPercent, 120_000, 17_000);
    try std.testing.expect(!b.backwards);
    // Stall-then-snap would jump about 3% in a frame at each burst.
    try std.testing.expect(b.max_step < 0.05);
    try std.testing.expectApproxEqAbs(64.0, b.last, 4.0);
}

test "the scan line stops within its look-ahead when progress stalls" {
    var animator = Animator{};
    _ = animator.update(10, false, 0);
    // 2% over the longest gap (4 s), so it may run 2% past the last report.
    _ = animator.update(12, false, 4000);
    var now: u64 = 4000;
    var shown: f64 = 0.0;
    while (now < 120_000) : (now += 16) shown = animator.update(12, false, now).?;
    try std.testing.expect(shown > 0.139 and shown <= 0.14 + 1e-9);
}

test "the scan line waits for the first lines and restarts for the IR pass" {
    var animator = Animator{};
    try std.testing.expectEqual(@as(?f64, null), animator.update(null, false, 0));
    try std.testing.expectEqual(@as(?f64, null), animator.update(0, false, 1000));
    try std.testing.expectApproxEqAbs(0.10, animator.update(10, false, 2000).?, 1e-9);
    _ = animator.update(100, false, 3000);
    try std.testing.expectEqual(@as(?f64, null), animator.update(0, true, 4000));
    try std.testing.expectApproxEqAbs(0.05, animator.update(5, true, 5000).?, 1e-9);
}
