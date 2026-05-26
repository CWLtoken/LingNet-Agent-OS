//! LingNet Agent OS V2.5 — Skill Scheduler
//! Priority queue + timeout + retry
//!
//! M2 FIX: Real timestamps via raw clock_gettime (monotonic)

const std = @import("std");
const linux = std.os.linux;

/// Task priority
pub const TaskPriority = enum(u8) {
    critical = 0,
    high = 1,
    normal = 2,
    low = 3,
    background = 4,
};

/// Task state
pub const TaskState = enum(u8) {
    pending = 0,
    running = 1,
    completed = 2,
    failed = 3,
    timeout = 4,
    cancelled = 5,
};

/// Scheduled task
pub const Task = struct {
    id: u64,
    name: []const u8,
    priority: TaskPriority,
    state: TaskState,
    timeout_ms: u64,
    retry_count: u32,
    max_retries: u32,
    created_at: u64,   // nanoseconds (monotonic)
    started_at: u64,   // nanoseconds (monotonic)
    completed_at: u64, // nanoseconds (monotonic)
    error_code: i32,
    handler: *const fn () callconv(.c) void,
};

/// Read monotonic clock in nanoseconds (M2 FIX: raw syscall, no std.time.Timer)
fn monotonicNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.clockid_t.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Priority queue comparison
pub fn taskCompare(context: void, a: Task, b: Task) std.math.Order {
    _ = context;
    return std.math.order(@intFromEnum(a.priority), @intFromEnum(b.priority));
}

/// Skill scheduler
pub const SkillScheduler = struct {
    allocator: std.mem.Allocator,
    task_queue: std.PriorityQueue(Task, void, taskCompare),
    completed_tasks: std.ArrayListAligned(Task, null),
    next_id: u64,
    max_concurrent: usize,
    default_timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator, max_concurrent: usize) SkillScheduler {
        return .{
            .allocator = allocator,
            .task_queue = std.PriorityQueue(Task, void, taskCompare).initContext({}),
            .completed_tasks = std.ArrayListAligned(Task, null).empty,
            .next_id = 1,
            .max_concurrent = max_concurrent,
            .default_timeout_ms = 30000,
        };
    }

    pub fn deinit(self: *SkillScheduler) void {
        self.task_queue.deinit(self.allocator);
        self.completed_tasks.deinit(self.allocator);
    }

    /// Submit a task
    pub fn submit(self: *SkillScheduler, name: []const u8, priority: TaskPriority, handler: *const fn () callconv(.c) void) !void {
        const id = self.next_id;
        self.next_id += 1;

        const now = monotonicNs();

        const task = Task{
            .id = id,
            .name = name,
            .priority = priority,
            .state = .pending,
            .timeout_ms = self.default_timeout_ms,
            .retry_count = 0,
            .max_retries = 3,
            .created_at = now,
            .started_at = 0,
            .completed_at = 0,
            .error_code = 0,
            .handler = handler,
        };

        try self.task_queue.push(self.allocator, task);
        std.log.info("[Scheduler] Task {d} submitted: {s} (priority={})", .{ id, name, @intFromEnum(priority) });
    }

    /// Execute next task (M2 FIX: real timeout check using monotonic clock)
    pub fn tick(self: *SkillScheduler) !bool {
        if (self.task_queue.count() == 0) return false;

        var task = self.task_queue.pop() orelse return false;
        task.state = .running;
        task.started_at = monotonicNs();

        // Check timeout: elapsed since submission
        const elapsed_ns = task.started_at - task.created_at;
        const elapsed_ms = elapsed_ns / 1_000_000;
        if (elapsed_ms > task.timeout_ms) {
            task.state = .timeout;
            task.error_code = -1;
            try self.completed_tasks.append(self.allocator, task);
            std.log.warn("[Scheduler] Task {d} timed out (elapsed={d}ms > timeout={d}ms)", .{
                task.id, elapsed_ms, task.timeout_ms,
            });
            return true;
        }

        // Execute
        task.handler();
        task.state = .completed;
        task.completed_at = monotonicNs();

        try self.completed_tasks.append(self.allocator, task);
        std.log.info("[Scheduler] Task {d} completed (took {d}ms)", .{
            task.id, (task.completed_at - task.started_at) / 1_000_000,
        });
        return true;
    }

    /// Cancel task
    pub fn cancel(self: *SkillScheduler, id: u64) !void {
        _ = self;
        _ = id;
        return error.TaskNotFound;
    }

    /// Get stats
    pub fn getStats(self: *SkillScheduler) SchedulerStats {
        return .{
            .queued = self.task_queue.count(),
            .completed = self.completed_tasks.items.len,
            .next_id = self.next_id,
        };
    }
};

pub const SchedulerStats = struct {
    queued: usize,
    completed: usize,
    next_id: u64,
};

// ─── Tests ───────────────────────────────────────────────────────────

test "SkillScheduler init/deinit" {
    var scheduler = SkillScheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();
    try std.testing.expectEqual(@as(usize, 0), scheduler.task_queue.count());
}

test "SkillScheduler submit and tick" {
    var scheduler = SkillScheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    const handler = struct {
        fn run() callconv(.c) void {}
    }.run;

    try scheduler.submit("test_task", .normal, &handler);
    try std.testing.expectEqual(@as(usize, 1), scheduler.task_queue.count());

    const executed = try scheduler.tick();
    try std.testing.expect(executed);
    try std.testing.expectEqual(@as(usize, 1), scheduler.completed_tasks.items.len);
}

test "SkillScheduler priority ordering" {
    var scheduler = SkillScheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    const handler = struct {
        fn run() callconv(.c) void {}
    }.run;

    try scheduler.submit("low", .low, &handler);
    try scheduler.submit("critical", .critical, &handler);
    try scheduler.submit("normal", .normal, &handler);

    _ = try scheduler.tick();
    try std.testing.expectEqualStrings("critical", scheduler.completed_tasks.items[0].name);
}

test "SkillScheduler getStats" {
    var scheduler = SkillScheduler.init(std.testing.allocator, 4);
    defer scheduler.deinit();

    const handler = struct {
        fn run() callconv(.c) void {}
    }.run;

    try scheduler.submit("task1", .normal, &handler);
    try scheduler.submit("task2", .high, &handler);

    const stats = scheduler.getStats();
    try std.testing.expectEqual(@as(usize, 2), stats.queued);
    try std.testing.expectEqual(@as(u64, 3), stats.next_id);
}

test "monotonicNs returns increasing values" {
    const t1 = monotonicNs();
    const t2 = monotonicNs();
    try std.testing.expect(t2 >= t1);
}
