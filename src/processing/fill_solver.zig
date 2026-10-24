//! Direct solver for the dust fills' linear systems: one unknown per masked
//! pixel, each coupled to the masked pixels within two steps (the
//! biharmonic stencil). Unknowns are ordered by nested dissection on the
//! pixel grid, each part split across its longer side by a separator two
//! pixels wide (the stencil's reach), and factored multifrontally without
//! pivoting. Away from the image edge the systems are symmetric positive
//! definite and factor as L D L^T; beside it the reflected stencils make
//! them a little unsymmetric, and they factor as L U, their pivots still
//! large. One factorization serves every channel.

const std = @import("std");

pub const Matrix = struct {
    n: usize,
    row_offsets: []const usize,
    columns: []const usize,
    values: []const f64,

    fn at(self: Matrix, row: usize, column: usize) f64 {
        var sum: f64 = 0.0;
        for (self.row_offsets[row]..self.row_offsets[row + 1]) |index| {
            if (self.columns[index] == column) sum += self.values[index];
        }
        return sum;
    }
};

/// Where the unknowns lie: `pixels[v]` is unknown v's pixel in a
/// `width` x `height` region. Matrix entries couple only unknowns within two
/// steps of each other (|dx| + |dy| <= 2).
pub const Grid = struct {
    width: usize,
    height: usize,
    pixels: []const usize,
};

/// Solves `matrix * solution = rhs` for `channels` right-hand sides stored
/// interleaved (`rhs[v * channels + c]`).
pub fn solve(
    allocator: std.mem.Allocator,
    grid: Grid,
    matrix: Matrix,
    rhs: []const f64,
    channels: usize,
    solution: []f64,
) !void {
    var factor = try Factor.init(allocator, grid, matrix);
    defer factor.deinit();
    try factor.solve(rhs, channels, solution);
}

const none = std.math.maxInt(u32);
const leaf_size: usize = 64;
const block: usize = 64;

const neighbors = [_][2]i32{
    .{ 0, 0 },  .{ -1, 0 }, .{ 1, 0 },  .{ 0, -1 }, .{ 0, 1 },
    .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 },  .{ -2, 0 },
    .{ 2, 0 },  .{ 0, -2 }, .{ 0, 2 },
};

const Node = struct {
    /// Pivots, in elimination order; a subtree's pivots come before its root's.
    begin: u32,
    end: u32,
    children: [2]u32 = .{ none, none },
    /// Later unknowns the subtree couples to, sorted: the front's other rows.
    update_start: u32 = 0,
    update_len: u32 = 0,
    /// Front rows x pivots: L, unit diagonal implied. Slices of the
    /// factor's storage, like `upper`.
    lower: []f64 = &.{},
    /// Pivots x front columns: U, diagonal included.
    upper: []f64 = &.{},
    /// Where the node's contribution block sits on the stack.
    stacked_at: usize = 0,

    fn pivots(self: Node) usize {
        return self.end - self.begin;
    }
};

const Factor = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    updates: []u32,
    /// Elimination position -> unknown.
    order: []u32,
    storage: []f64 = &.{},
    /// Symmetric systems keep L and D only (D on L's diagonal).
    symmetric: bool = false,

    fn init(allocator: std.mem.Allocator, grid: Grid, matrix: Matrix) !Factor {
        const n = grid.pixels.len;
        const var_of_pixel = try allocator.alloc(u32, grid.width * grid.height);
        defer allocator.free(var_of_pixel);
        @memset(var_of_pixel, none);
        for (grid.pixels, 0..) |pixel, v| var_of_pixel[pixel] = @intCast(v);

        const order = try allocator.alloc(u32, n);
        errdefer allocator.free(order);
        for (order, 0..) |*slot, v| slot.* = @intCast(v);

        var node_list: std.ArrayList(Node) = .empty;
        defer node_list.deinit(allocator);
        {
            const hist = try allocator.alloc(u32, @max(grid.width, grid.height) + 2);
            defer allocator.free(hist);
            var dissector = Dissector{ .allocator = allocator, .grid = grid, .hist = hist, .nodes = &node_list };
            if (n > 0) _ = try dissector.dissect(order, 0);
        }
        const nodes = try allocator.dupe(Node, node_list.items);
        errdefer allocator.free(nodes);

        const position = try allocator.alloc(u32, n);
        defer allocator.free(position);
        for (order, 0..) |v, p| position[v] = @intCast(p);

        var neighborhood = Neighborhood{ .grid = grid, .var_of_pixel = var_of_pixel };
        const updates = try symbolic(allocator, nodes, order, position, &neighborhood);
        errdefer allocator.free(updates);

        var factor = Factor{ .allocator = allocator, .nodes = nodes, .updates = updates, .order = order };
        errdefer allocator.free(factor.storage);
        try factor.numeric(matrix, position, &neighborhood);
        return factor;
    }

    fn deinit(self: *Factor) void {
        self.allocator.free(self.storage);
        self.allocator.free(self.nodes);
        self.allocator.free(self.updates);
        self.allocator.free(self.order);
    }

    fn updateOf(self: Factor, node: Node) []const u32 {
        return self.updates[node.update_start..][0..node.update_len];
    }

    fn numeric(self: *Factor, matrix: Matrix, position: []const u32, neighborhood: *Neighborhood) !void {
        const allocator = self.allocator;
        const n = self.order.len;
        self.symmetric = isSymmetric(matrix);

        // Every buffer sized up front: the factors in one block, one front
        // reused by every node, and the contribution blocks on a stack (a
        // node's children's blocks are the top of it when its turn comes).
        var storage_len: usize = 0;
        var widest: usize = 0;
        var top: usize = 0;
        var stack_len: usize = 0;
        for (self.nodes) |*node| {
            const k = node.pivots();
            const f = k + node.update_len;
            storage_len += if (self.symmetric) f * k else 2 * f * k;
            widest = @max(widest, f);
            for (node.children) |child| {
                if (child != none) top = @min(top, self.nodes[child].stacked_at);
            }
            node.stacked_at = top;
            top += @as(usize, node.update_len) * node.update_len;
            stack_len = @max(stack_len, top);
        }
        self.storage = try allocator.alloc(f64, storage_len);
        const front_buffer = try allocator.alloc(f64, widest * widest);
        defer allocator.free(front_buffer);
        const stack = try allocator.alloc(f64, stack_len);
        defer allocator.free(stack);
        const local = try allocator.alloc(u32, n);
        defer allocator.free(local);
        const panel = try allocator.alloc(f64, 2 * block * widest);
        defer allocator.free(panel);

        var floor: f64 = 0.0;
        for (0..n) |v| floor = @max(floor, @abs(matrix.at(v, v)));
        floor *= 1e-12;

        var used: usize = 0;
        for (self.nodes) |*node| {
            const k = node.pivots();
            const update = self.updateOf(node.*);
            const f = k + update.len;
            const front = front_buffer[0 .. f * f];
            @memset(front, 0.0);
            for (0..k) |i| local[node.begin + i] = @intCast(i);
            for (update, 0..) |q, u| local[q] = @intCast(k + u);

            for (node.begin..node.end) |p| {
                const row_var = self.order[p];
                const row = local[p];
                for (neighborhood.of(row_var)) |column_var| {
                    const q = position[column_var];
                    if (q < p) continue;
                    const column = local[q];
                    front[column * f + row] += matrix.at(column_var, row_var);
                    if (q != p and !self.symmetric) front[row * f + column] += matrix.at(row_var, column_var);
                }
            }
            for (node.children) |child| {
                if (child == none) continue;
                const child_node = self.nodes[child];
                const child_update = self.updateOf(child_node);
                const contribution = stack[child_node.stacked_at..];
                for (child_update, 0..) |qa, a| {
                    const front_row = front[local[qa] * f ..];
                    const contribution_row = contribution[a * child_update.len ..];
                    // Symmetric fronts hold their lower triangle only.
                    const columns = if (self.symmetric) child_update[0 .. a + 1] else child_update;
                    for (columns, 0..) |qb, b| front_row[local[qb]] += contribution_row[b];
                }
            }

            if (self.symmetric) {
                try partialLdl(front, f, k, floor, panel);
            } else {
                try partialLu(front, f, k, floor);
            }

            node.lower = self.storage[used..][0 .. f * k];
            used += f * k;
            for (0..f) |r| @memcpy(node.lower[r * k ..][0..k], front[r * f ..][0..k]);
            if (!self.symmetric) {
                node.upper = self.storage[used..][0 .. k * f];
                used += k * f;
                @memcpy(node.upper, front[0 .. k * f]);
            }
            const contribution = stack[node.stacked_at..];
            for (0..update.len) |r| {
                const length = if (self.symmetric) r + 1 else update.len;
                @memcpy(contribution[r * update.len ..][0..length], front[(k + r) * f + k ..][0..length]);
            }
        }
    }

    fn solve(self: Factor, rhs: []const f64, channels: usize, solution: []f64) !void {
        const allocator = self.allocator;
        const n = self.order.len;
        // Channel-major and in elimination order, so each node's pivots are
        // one contiguous run per channel; each factor row is read once for
        // every channel.
        const work = try allocator.alloc(f64, n * channels);
        defer allocator.free(work);
        for (self.order, 0..) |v, p| {
            for (0..channels) |c| work[c * n + p] = rhs[v * channels + c];
        }
        var widest: usize = 0;
        for (self.nodes) |node| widest = @max(widest, node.update_len);
        const gathered = try allocator.alloc(f64, widest * channels);
        defer allocator.free(gathered);

        for (self.nodes) |node| {
            const k = node.pivots();
            const update = self.updateOf(node);
            for (@min(1, k)..k) |r| {
                const row = node.lower[r * k ..][0..r];
                for (0..channels) |c| {
                    const y = work[c * n + node.begin ..][0..k];
                    y[r] -= dot(row, y[0..r]);
                }
            }
            for (update, k..) |q, r| {
                const row = node.lower[r * k ..][0..k];
                for (0..channels) |c| work[c * n + q] -= dot(row, work[c * n + node.begin ..][0..k]);
            }
        }

        var index = self.nodes.len;
        while (index > 0) {
            index -= 1;
            const node = self.nodes[index];
            const k = node.pivots();
            const update = self.updateOf(node);
            if (self.symmetric) {
                // L^T x = D^-1 y, a row of L at a time.
                for (0..channels) |c| {
                    const x = work[c * n + node.begin ..][0..k];
                    for (x, 0..) |*value, r| value.* /= node.lower[r * k + r];
                }
                for (update, k..) |q, r| {
                    const row = node.lower[r * k ..][0..k];
                    for (0..channels) |c| axpy(work[c * n + node.begin ..][0..k], row, -work[c * n + q]);
                }
                var j = k;
                while (j > 1) {
                    j -= 1;
                    const row = node.lower[j * k ..][0..j];
                    for (0..channels) |c| {
                        const x = work[c * n + node.begin ..][0..k];
                        axpy(x[0..j], row, -x[j]);
                    }
                }
            } else {
                const f = k + update.len;
                for (0..channels) |c| {
                    for (update, gathered[c * widest ..][0..update.len]) |q, *value| value.* = work[c * n + q];
                }
                var r = k;
                while (r > 0) {
                    r -= 1;
                    const row = node.upper[r * f ..][0..f];
                    for (0..channels) |c| {
                        const x = work[c * n + node.begin ..][0..k];
                        const sum = dot(row[r + 1 .. k], x[r + 1 .. k]) + dot(row[k..f], gathered[c * widest ..][0..update.len]);
                        x[r] = (x[r] - sum) / row[r];
                    }
                }
            }
        }

        for (self.order, 0..) |v, p| {
            for (0..channels) |c| solution[v * channels + c] = work[c * n + p];
        }
    }
};

fn isSymmetric(matrix: Matrix) bool {
    for (0..matrix.n) |row| {
        for (matrix.row_offsets[row]..matrix.row_offsets[row + 1]) |index| {
            if (matrix.at(matrix.columns[index], row) != matrix.values[index]) return false;
        }
    }
    return true;
}

fn dot(a: []const f64, b: []const f64) f64 {
    const V = @Vector(4, f64);
    var acc0: V = @splat(0.0);
    var acc1: V = @splat(0.0);
    var i: usize = 0;
    while (i + 8 <= a.len) : (i += 8) {
        acc0 = @mulAdd(V, a[i..][0..4].*, b[i..][0..4].*, acc0);
        acc1 = @mulAdd(V, a[i + 4 ..][0..4].*, b[i + 4 ..][0..4].*, acc1);
    }
    var sum = @reduce(.Add, acc0 + acc1);
    while (i < a.len) : (i += 1) sum = @mulAdd(f64, a[i], b[i], sum);
    return sum;
}

/// The unknowns within two steps of an unknown, itself included.
const Neighborhood = struct {
    grid: Grid,
    var_of_pixel: []const u32,
    found: [neighbors.len]u32 = undefined,

    fn of(self: *Neighborhood, v: u32) []const u32 {
        const pixel = self.grid.pixels[v];
        const x: i64 = @intCast(pixel % self.grid.width);
        const y: i64 = @intCast(pixel / self.grid.width);
        var count: usize = 0;
        for (neighbors) |offset| {
            const nx = x + offset[0];
            const ny = y + offset[1];
            if (nx < 0 or ny < 0 or nx >= self.grid.width or ny >= self.grid.height) continue;
            const other = self.var_of_pixel[@as(usize, @intCast(ny)) * self.grid.width + @as(usize, @intCast(nx))];
            if (other == none) continue;
            self.found[count] = other;
            count += 1;
        }
        return self.found[0..count];
    }
};

/// Each node's update set: the later unknowns its pivots couple to,
/// directly or through its children's fronts.
fn symbolic(
    allocator: std.mem.Allocator,
    nodes: []Node,
    order: []const u32,
    position: []const u32,
    neighborhood: *Neighborhood,
) ![]u32 {
    const mark = try allocator.alloc(u32, order.len);
    defer allocator.free(mark);
    @memset(mark, none);
    var updates: std.ArrayList(u32) = .empty;
    errdefer updates.deinit(allocator);
    for (nodes, 0..) |*node, id| {
        const start = updates.items.len;
        const stamp: u32 = @intCast(id);
        for (node.begin..node.end) |p| {
            for (neighborhood.of(order[p])) |other| {
                const q = position[other];
                if (q < node.end or mark[q] == stamp) continue;
                mark[q] = stamp;
                try updates.append(allocator, q);
            }
        }
        for (node.children) |child| {
            if (child == none) continue;
            const child_node = nodes[child];
            for (child_node.update_start..child_node.update_start + child_node.update_len) |index| {
                const q = updates.items[index];
                if (q < node.end or mark[q] == stamp) continue;
                mark[q] = stamp;
                try updates.append(allocator, q);
            }
        }
        std.mem.sort(u32, updates.items[start..], {}, std.sort.asc(u32));
        node.update_start = @intCast(start);
        node.update_len = @intCast(updates.items.len - start);
    }
    return updates.toOwnedSlice(allocator);
}

const Dissector = struct {
    allocator: std.mem.Allocator,
    grid: Grid,
    hist: []u32,
    nodes: *std.ArrayList(Node),

    const Axis = enum { x, y };

    fn coordinate(self: Dissector, v: u32, axis: Axis) u32 {
        const pixel = self.grid.pixels[v];
        return @intCast(switch (axis) {
            .x => pixel % self.grid.width,
            .y => pixel / self.grid.width,
        });
    }

    /// Orders `part` (unknowns at elimination positions `base..`) and
    /// returns its root node; children are appended before their parent.
    fn dissect(self: *Dissector, part: []u32, base: usize) !u32 {
        if (part.len > leaf_size) {
            if (self.split(part)) |sizes| {
                const left = try self.dissect(part[0..sizes[0]], base);
                const right = try self.dissect(part[sizes[0]..][0..sizes[1]], base + sizes[0]);
                return self.addNode(.{
                    .begin = @intCast(base + sizes[0] + sizes[1]),
                    .end = @intCast(base + part.len),
                    .children = .{ left, right },
                });
            }
        }
        return self.addNode(.{ .begin = @intCast(base), .end = @intCast(base + part.len) });
    }

    fn addNode(self: *Dissector, node: Node) !u32 {
        try self.nodes.append(self.allocator, node);
        return @intCast(self.nodes.items.len - 1);
    }

    /// Partitions `part` into [left | right | separator] across its longer
    /// side; returns the left and right sizes, or null when it cannot split.
    fn split(self: *Dissector, part: []u32) ?[2]usize {
        var lo = [2]u32{ std.math.maxInt(u32), std.math.maxInt(u32) };
        var hi = [2]u32{ 0, 0 };
        for (part) |v| {
            inline for (.{ Axis.x, Axis.y }, 0..) |axis, a| {
                const c = self.coordinate(v, axis);
                lo[a] = @min(lo[a], c);
                hi[a] = @max(hi[a], c);
            }
        }
        const first: Axis = if (hi[0] - lo[0] >= hi[1] - lo[1]) .x else .y;
        const second: Axis = if (first == .x) .y else .x;
        return self.splitAlong(part, first, lo[@intFromEnum(first)], hi[@intFromEnum(first)]) orelse
            self.splitAlong(part, second, lo[@intFromEnum(second)], hi[@intFromEnum(second)]);
    }

    fn splitAlong(self: *Dissector, part: []u32, axis: Axis, lo: u32, hi: u32) ?[2]usize {
        // Both sides must keep a line: the separator's two lines lie in
        // [lo + 1, hi - 1].
        if (hi - lo < 3) return null;
        const extent: usize = hi - lo + 1;
        const hist = self.hist[0..extent];
        @memset(hist, 0);
        for (part) |v| hist[self.coordinate(v, axis) - lo] += 1;

        var cumulative: usize = 0;
        var median: usize = 0;
        for (hist, 0..) |count, c| {
            cumulative += count;
            if (cumulative * 2 >= part.len) {
                median = c;
                break;
            }
        }
        median = std.math.clamp(median, 1, extent - 3);
        // The thinnest pair of lines near the median: fewer separator
        // unknowns, at little cost in balance.
        const reach = extent / 10;
        var best = median;
        var best_cost: usize = hist[median] + hist[median + 1];
        var m = @max(1, median -| reach);
        while (m <= @min(extent - 3, median + reach)) : (m += 1) {
            const cost: usize = hist[m] + hist[m + 1];
            const distance = if (m > median) m - median else median - m;
            const best_distance = if (best > median) best - median else median - best;
            if (cost < best_cost or (cost == best_cost and distance < best_distance)) {
                best = m;
                best_cost = cost;
            }
        }

        const cut: u32 = lo + @as(u32, @intCast(best));
        var low: usize = 0;
        var mid: usize = 0;
        var high: usize = part.len;
        // Three-way partition: left (< cut), right (> cut + 1), separator.
        while (mid < high) {
            const c = self.coordinate(part[mid], axis);
            if (c < cut) {
                std.mem.swap(u32, &part[low], &part[mid]);
                low += 1;
                mid += 1;
            } else if (c > cut + 1) {
                mid += 1;
            } else {
                high -= 1;
                std.mem.swap(u32, &part[mid], &part[high]);
            }
        }
        return .{ low, high - low };
    }
};

/// Eliminates the first `k` rows and columns of the row-major `f` x `f`
/// front in place: L (unit diagonal) below, U on and right of the diagonal,
/// and the Schur complement left in the trailing block.
fn partialLu(front: []f64, f: usize, k: usize, floor: f64) !void {
    var start: usize = 0;
    while (start < k) : (start += block) {
        const panel_end = @min(k, start + block);
        // Row by row: each row's L entries in the block, and for the block's
        // own rows their U entries out to the front's edge. Rows below the
        // block get the rest of their update from the product after.
        for (start..f) |i| {
            const row = front[i * f ..];
            const last = @min(i, panel_end);
            for (start..last) |t| {
                const pivot_row = front[t * f ..];
                const l = row[t] / pivot_row[t];
                row[t] = l;
                if (l == 0.0) continue;
                const column_end = if (i < panel_end) f else panel_end;
                axpy(row[t + 1 .. column_end], pivot_row[t + 1 .. column_end], -l);
            }
            if (i >= start and i < panel_end) {
                const pivot = row[i];
                if (!(@abs(pivot) > floor)) return error.SingularFillSystem;
            }
        }
        if (panel_end < f) {
            subtractProduct(front, f, panel_end, f, start, panel_end);
        }
    }
}

/// The symmetric counterpart of `partialLu` on the front's lower triangle:
/// L (unit diagonal) below the diagonal, D on it, the Schur complement's
/// lower triangle left in the trailing block. `panel` holds 2 * block * f.
fn partialLdl(front: []f64, f: usize, k: usize, floor: f64, panel: []f64) !void {
    var start: usize = 0;
    while (start < k) : (start += block) {
        const panel_end = @min(k, start + block);
        const width = panel_end - start;
        const rest = f - panel_end;
        // W = L D for the rows below the block, row by row, and L^T packed
        // for the product after.
        const scaled = panel[0 .. block * f];
        const transposed = panel[block * f ..][0 .. block * f];
        var w_buffer: [block]f64 = undefined;
        for (start..f) |i| {
            const row = front[i * f ..];
            const below = i >= panel_end;
            const w = if (below) scaled[(i - panel_end) * block ..][0..width] else w_buffer[0..width];
            const last = @min(i, panel_end);
            for (start..last) |t| {
                const a = row[t] - dot(w[0 .. t - start], front[t * f + start ..][0 .. t - start]);
                w[t - start] = a;
                row[t] = a / front[t * f + t];
            }
            if (!below) {
                const d = row[i] - dot(w[0 .. i - start], row[start..i]);
                if (!(@abs(d) > floor)) return error.SingularFillSystem;
                row[i] = d;
            } else {
                for (0..width) |t| transposed[t * rest + (i - panel_end)] = row[start + t];
            }
        }
        if (rest > 0) subtractLowerProduct(front, f, panel_end, scaled, transposed, width, rest);
    }
}

/// front[i][j] -= sum over t of scaled[i][t] * transposed[t][j] for
/// first <= j <= i < f (indexes of scaled and transposed relative to first),
/// in tiles, so a few entries above the diagonal are touched too.
fn subtractLowerProduct(front: []f64, f: usize, first: usize, scaled: []const f64, transposed: []const f64, depth: usize, rest: usize) void {
    const V = @Vector(4, f64);
    var i: usize = 0;
    while (i < rest) : (i += 4) {
        const rows = @min(4, rest - i);
        const column_end = @min(rest, i + 4);
        var j: usize = 0;
        while (j < column_end) : (j += 8) {
            const columns = @min(8, rest - j);
            if (rows == 4 and columns == 8) {
                var acc: [4][2]V = @splat(@splat(@splat(0.0)));
                for (0..depth) |t| {
                    const b_row = transposed[t * rest + j ..];
                    const b0: V = b_row[0..4].*;
                    const b1: V = b_row[4..8].*;
                    inline for (0..4) |r| {
                        const a: V = @splat(scaled[(i + r) * block + t]);
                        acc[r][0] = @mulAdd(V, a, b0, acc[r][0]);
                        acc[r][1] = @mulAdd(V, a, b1, acc[r][1]);
                    }
                }
                inline for (0..4) |r| {
                    const c_row = front[(first + i + r) * f + first + j ..];
                    const c0: V = c_row[0..4].*;
                    const c1: V = c_row[4..8].*;
                    c_row[0..4].* = c0 - acc[r][0];
                    c_row[4..8].* = c1 - acc[r][1];
                }
            } else {
                for (0..rows) |r| {
                    for (0..columns) |c| {
                        var sum: f64 = 0.0;
                        for (0..depth) |t| sum = @mulAdd(f64, scaled[(i + r) * block + t], transposed[t * rest + j + c], sum);
                        front[(first + i + r) * f + first + j + c] -= sum;
                    }
                }
            }
        }
    }
}

fn axpy(y: []f64, x: []const f64, alpha: f64) void {
    const V = @Vector(4, f64);
    const a: V = @splat(alpha);
    var i: usize = 0;
    while (i + 4 <= y.len) : (i += 4) {
        const xv: V = x[i..][0..4].*;
        const yv: V = y[i..][0..4].*;
        y[i..][0..4].* = @mulAdd(V, a, xv, yv);
    }
    while (i < y.len) : (i += 1) y[i] = @mulAdd(f64, alpha, x[i], y[i]);
}

/// front[i][j] -= sum over t in [depth_start, depth_end) of
/// front[i][t] * front[t][j], for i and j in [first, f).
fn subtractProduct(front: []f64, stride: usize, first: usize, last: usize, depth_start: usize, depth_end: usize) void {
    const V = @Vector(4, f64);
    const depth = depth_end - depth_start;
    const column_block: usize = 256;
    var column_start = first;
    while (column_start < last) : (column_start += column_block) {
        const column_end = @min(last, column_start + column_block);
        var i = first;
        while (i < last) : (i += 4) {
            const rows = @min(4, last - i);
            var j = column_start;
            while (j < column_end) : (j += 8) {
                const columns = @min(8, column_end - j);
                if (rows == 4 and columns == 8) {
                    var acc: [4][2]V = @splat(@splat(@splat(0.0)));
                    for (0..depth) |t| {
                        const b_row = front[(depth_start + t) * stride + j ..];
                        const b0: V = b_row[0..4].*;
                        const b1: V = b_row[4..8].*;
                        inline for (0..4) |r| {
                            const a: V = @splat(front[(i + r) * stride + depth_start + t]);
                            acc[r][0] = @mulAdd(V, a, b0, acc[r][0]);
                            acc[r][1] = @mulAdd(V, a, b1, acc[r][1]);
                        }
                    }
                    inline for (0..4) |r| {
                        const c_row = front[(i + r) * stride + j ..];
                        const c0: V = c_row[0..4].*;
                        const c1: V = c_row[4..8].*;
                        c_row[0..4].* = c0 - acc[r][0];
                        c_row[4..8].* = c1 - acc[r][1];
                    }
                } else {
                    for (0..rows) |r| {
                        const a_row = front[(i + r) * stride + depth_start ..];
                        for (0..columns) |c| {
                            var sum: f64 = 0.0;
                            for (0..depth) |t| sum = @mulAdd(f64, a_row[t], front[(depth_start + t) * stride + j + c], sum);
                            front[(i + r) * stride + j + c] -= sum;
                        }
                    }
                }
            }
        }
    }
}

fn testSystem(allocator: std.mem.Allocator, width: usize, height: usize, mask: []const bool, skew: f64) !struct {
    pixels: []usize,
    row_offsets: []usize,
    columns: []usize,
    values: []f64,
} {
    var var_of_pixel = try allocator.alloc(u32, width * height);
    defer allocator.free(var_of_pixel);
    @memset(var_of_pixel, none);
    var pixels: std.ArrayList(usize) = .empty;
    errdefer pixels.deinit(allocator);
    for (mask, 0..) |masked, pixel| {
        if (!masked) continue;
        var_of_pixel[pixel] = @intCast(pixels.items.len);
        try pixels.append(allocator, pixel);
    }
    var row_offsets: std.ArrayList(usize) = .empty;
    errdefer row_offsets.deinit(allocator);
    var columns: std.ArrayList(usize) = .empty;
    errdefer columns.deinit(allocator);
    var values: std.ArrayList(f64) = .empty;
    errdefer values.deinit(allocator);
    try row_offsets.append(allocator, 0);
    for (pixels.items, 0..) |pixel, row| {
        const x: i64 = @intCast(pixel % width);
        const y: i64 = @intCast(pixel / width);
        for (neighbors) |offset| {
            const other = var_of_pixel[@as(usize, @intCast(y + offset[1])) * width + @as(usize, @intCast(x + offset[0]))];
            if (other == none) continue;
            const distance = @abs(offset[0]) + @abs(offset[1]);
            var coefficient: f64 = if (distance == 0) 20.0 else if (distance == 2 and offset[0] != 0 and offset[1] != 0) 2.0 else if (distance == 1) -8.0 else 1.0;
            if (other > row) coefficient += skew;
            try columns.append(allocator, other);
            try values.append(allocator, coefficient);
        }
        try row_offsets.append(allocator, columns.items.len);
    }
    return .{
        .pixels = try pixels.toOwnedSlice(allocator),
        .row_offsets = try row_offsets.toOwnedSlice(allocator),
        .columns = try columns.toOwnedSlice(allocator),
        .values = try values.toOwnedSlice(allocator),
    };
}

fn expectSolves(width: usize, height: usize, mask: []const bool, skew: f64) !void {
    const allocator = std.testing.allocator;
    const system = try testSystem(allocator, width, height, mask, skew);
    defer {
        allocator.free(system.pixels);
        allocator.free(system.row_offsets);
        allocator.free(system.columns);
        allocator.free(system.values);
    }
    const n = system.pixels.len;
    const channels = 3;
    const rhs = try allocator.alloc(f64, n * channels);
    defer allocator.free(rhs);
    var prng = std.Random.DefaultPrng.init(7);
    for (rhs) |*value| value.* = prng.random().float(f64) - 0.5;
    const solution = try allocator.alloc(f64, n * channels);
    defer allocator.free(solution);
    const matrix = Matrix{ .n = n, .row_offsets = system.row_offsets, .columns = system.columns, .values = system.values };
    try solve(allocator, .{ .width = width, .height = height, .pixels = system.pixels }, matrix, rhs, channels, solution);
    for (0..n) |row| {
        for (0..channels) |c| {
            var sum: f64 = 0.0;
            for (system.row_offsets[row]..system.row_offsets[row + 1]) |index| sum += system.values[index] * solution[system.columns[index] * channels + c];
            try std.testing.expectApproxEqAbs(rhs[row * channels + c], sum, 1e-9);
        }
    }
}

fn diskMask(allocator: std.mem.Allocator, size: usize, radius: f64) ![]bool {
    const mask = try allocator.alloc(bool, size * size);
    const centre = @as(f64, @floatFromInt(size)) / 2.0;
    for (mask, 0..) |*masked, pixel| {
        const dx = @as(f64, @floatFromInt(pixel % size)) - centre;
        const dy = @as(f64, @floatFromInt(pixel / size)) - centre;
        masked.* = dx * dx + dy * dy <= radius * radius;
    }
    return mask;
}

test "fill solver solves a small fill exactly" {
    const mask = try diskMask(std.testing.allocator, 16, 5.0);
    defer std.testing.allocator.free(mask);
    try expectSolves(16, 16, mask, 0.0);
}

test "fill solver solves a large fill through many fronts and blocks" {
    const mask = try diskMask(std.testing.allocator, 120, 55.0);
    defer std.testing.allocator.free(mask);
    try expectSolves(120, 120, mask, 0.0);
}

test "fill solver solves unsymmetric systems, as beside the image edge" {
    const mask = try diskMask(std.testing.allocator, 60, 25.0);
    defer std.testing.allocator.free(mask);
    try expectSolves(60, 60, mask, 0.3);
}

test "fill solver solves thin and scattered fills" {
    const allocator = std.testing.allocator;
    const size = 90;
    const mask = try allocator.alloc(bool, size * size);
    defer allocator.free(mask);
    for (mask, 0..) |*masked, pixel| {
        const x = pixel % size;
        const y = pixel / size;
        // A diagonal hair two pixels wide, and specks apart from it.
        const hair = x >= 4 and x < size - 4 and y >= 4 and y < size - 4 and (x + 1 == y or x == y);
        const speck = (x % 17 < 3) and (y % 13 < 3) and x > 4 and y > 4 and x < size - 4 and y < size - 4;
        masked.* = hair or speck;
    }
    try expectSolves(size, size, mask, 0.0);
}
