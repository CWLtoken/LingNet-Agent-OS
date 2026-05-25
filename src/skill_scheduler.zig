//! LingNet Agent OS V2.5 — Skill Scheduler
//! 优先级队列 + 超时 + 重试

const std = @import("std");

/// 任务优先级
pub const TaskPriority = enum(u8) {
    critical = 0,
    high = 1,
    normal = 2,
    low = 3,
    background = 4,
};

/// 任务状态
pub const TaskState = enum(u8) {
    pending = 0,
    running = 1,
    completed = 2,
    failed = 3,
    timeout = 4,
    cancelled = 5,
};

/// 调度任务
pub const Task = struct {
    id: u64,
    name: []const u8,
    priority: TaskPriority,
    state: TaskState,
    timeout_ms: u64,
    retry_count: u32,
    max_retries: u32,
    created_at: i64,
    started_at: i64,
    completed_at: i64,
    error_code: i32,
    handler: *const fn () callconv(.c) void,
};

/// 优先级队列比较函数
pub fn taskCompare(context: void, a: Task, b: Task) std.math.Order {
    _ = context;
    return std.math.order(@intFromEnum(a.priority), @intFromEnum(b.priority));
}

/// Skill 调度器
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

    /// 提交任务
    pub fn submit(self: *SkillScheduler, name: []const u8, priority: TaskPriority, handler: *const fn () callconv(.c) void) !void {
        const id = self.next_id;
        self.next_id += 1;

        const task = Task{
            .id = id,
            .name = name,
            .priority = priority,
            .state = .pending,
            .timeout_ms = self.default_timeout_ms,
            .retry_count = 0,
            .max_retries = 3,
            .created_at = 0,
            .started_at = 0,
            .completed_at = 0,
            .error_code = 0,
            .handler = handler,
        };

        try self.task_queue.push(self.allocator, task);
        std.log.info("[Scheduler] Task {d} submitted: {s} (priority={})", .{ id, name, @intFromEnum(priority) });
    }

    /// 执行下一个任务
    pub fn tick(self: *SkillScheduler) !bool {
        if (self.task_queue.count() == 0) return false;

        var task = self.task_queue.pop() orelse return false;
        task.state = .running;
        task.started_at = 0;

        // 检查超时 (简化: 用秒级时间戳)
        const elapsed_s = task.started_at - task.created_at;
        if (elapsed_s * 1000 > task.timeout_ms) {
            task.state = .timeout;
            task.error_code = -1;
            try self.completed_tasks.append(self.allocator, task);
            std.log.warn("[Scheduler] Task {d} timed out", .{task.id});
            return true;
        }

        // 执行
        task.handler();
        task.state = .completed;
        task.completed_at = 0;

        try self.completed_tasks.append(self.allocator, task);
        std.log.info("[Scheduler] Task {d} completed", .{task.id});
        return true;
    }

    /// 取消任务 (简化: 不支持从队列中间移除)
    pub fn cancel(self: *SkillScheduler, id: u64) !void {
        _ = self;
        _ = id;
        // TODO: 实现取消
        return error.TaskNotFound;
    }

    /// 获取统计
    pub fn getStats(self: *SkillScheduler) SchedulerStats {
        return .{
            .queued = self.task_queue.count(),
            .completed = self.completed_tasks.items.len,
            .next_id = self.next_id,
        };
    }
};

/// 调度器统计
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

    // 第一个执行的应该是 critical
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
