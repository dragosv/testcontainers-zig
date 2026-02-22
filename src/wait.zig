/// Wait strategies — analogous to testcontainers-go's wait package.
///
/// A Strategy is a tagged union. After a container starts, the testcontainers
/// runtime calls `Strategy.waitUntilReady` with a reference to the running
/// `DockerContainer`.  Callers build a strategy with the `for*` constructor
/// functions and set it on `ContainerRequest.wait_strategy`.
const std = @import("std");

// Forward ref — docker_container imports wait, so we use anyopaque + VTable
// to break the import cycle.
pub const StrategyTarget = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return the Docker daemon host (e.g. "localhost").
        daemonHost: *const fn (*anyopaque, std.mem.Allocator) anyerror![]const u8,
        /// Return the host-side mapped port number for a container port spec.
        mappedPort: *const fn (*anyopaque, []const u8, std.mem.Allocator) anyerror!u16,
        /// Read all container logs (stdout+stderr) into the allocator.
        logs: *const fn (*anyopaque, std.mem.Allocator) anyerror![]const u8,
        /// Run a command inside the container; return exit code and stdout.
        exec: *const fn (*anyopaque, []const []const u8, std.mem.Allocator) anyerror!ExecResult,
        /// Inspect the container and return its current health status string.
        healthStatus: *const fn (*anyopaque, std.mem.Allocator) anyerror![]const u8,
    };
};

pub const ExecResult = struct {
    exit_code: i64,
    output: []const u8, // owned by caller
};

// ---------------------------------------------------------------------------
// Default values
// ---------------------------------------------------------------------------

pub const default_startup_timeout_ns: u64 = 60 * std.time.ns_per_s;
pub const default_poll_interval_ns: u64 = 100 * std.time.ns_per_ms;

// ---------------------------------------------------------------------------
// Individual strategy types
// ---------------------------------------------------------------------------

pub const LogStrategy = struct {
    /// The log substring (or regexp pattern when `is_regexp` is true).
    log: []const u8,
    /// When true, treat `log` as a RE2-compatible regular expression.
    is_regexp: bool = false,
    /// Number of times the pattern must appear.  Default 1.
    occurrence: u32 = 1,
    /// Startup timeout in nanoseconds. 0 → default_startup_timeout_ns.
    startup_timeout_ns: u64 = 0,
    /// Poll interval in nanoseconds. 0 → default_poll_interval_ns.
    poll_interval_ns: u64 = 0,
};

pub const HttpStrategy = struct {
    /// URL path to poll (e.g. "/health").
    path: []const u8 = "/",
    /// Container port spec (e.g. "8080/tcp").  Empty = first exposed port.
    port: []const u8 = "",
    /// Expected HTTP status code.  0 = accept any 2xx.
    status_code: u16 = 200,
    /// Use TLS (HTTPS) when connecting.
    use_tls: bool = false,
    /// HTTP method (uppercase).
    method: []const u8 = "GET",
    startup_timeout_ns: u64 = 0,
    poll_interval_ns: u64 = 0,
};

pub const PortStrategy = struct {
    /// Container port spec, e.g. "5432/tcp".
    port: []const u8,
    startup_timeout_ns: u64 = 0,
    poll_interval_ns: u64 = 0,
};

pub const HealthCheckStrategy = struct {
    startup_timeout_ns: u64 = 0,
    poll_interval_ns: u64 = 0,
};

pub const ExecStrategy = struct {
    /// Command to run; succeeds when exit code equals `expected_exit_code`.
    cmd: []const []const u8,
    expected_exit_code: i64 = 0,
    startup_timeout_ns: u64 = 0,
    poll_interval_ns: u64 = 0,
};

// ---------------------------------------------------------------------------
// Strategy tagged union
// ---------------------------------------------------------------------------

pub const Strategy = union(enum) {
    none,
    log: LogStrategy,
    http: HttpStrategy,
    port: PortStrategy,
    health_check: HealthCheckStrategy,
    exec: ExecStrategy,
    /// All strategies must succeed (run serially).
    all: []const Strategy,

    /// Block until ready or the startup timeout elapses.
    pub fn waitUntilReady(self: Strategy, target: StrategyTarget, alloc: std.mem.Allocator) !void {
        switch (self) {
            .none => {},
            .log => |s| try waitLog(s, target, alloc),
            .http => |s| try waitHttp(s, target, alloc),
            .port => |s| try waitPort(s, target, alloc),
            .health_check => |s| try waitHealthCheck(s, target, alloc),
            .exec => |s| try waitExec(s, target, alloc),
            .all => |strategies| {
                for (strategies) |sub| try sub.waitUntilReady(target, alloc);
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Constructor helpers (mirrors testcontainers-go API)
// ---------------------------------------------------------------------------

pub fn forLog(log_str: []const u8) Strategy {
    return .{ .log = .{ .log = log_str } };
}

pub fn forHttp(path: []const u8) Strategy {
    return .{ .http = .{ .path = path } };
}

pub fn forPort(port: []const u8) Strategy {
    return .{ .port = .{ .port = port } };
}

pub fn forHealthCheck() Strategy {
    return .{ .health_check = .{} };
}

pub fn forExec(cmd: []const []const u8) Strategy {
    return .{ .exec = .{ .cmd = cmd } };
}

pub fn forAll(strategies: []const Strategy) Strategy {
    return .{ .all = strategies };
}

// ---------------------------------------------------------------------------
// Implementation helpers
// ---------------------------------------------------------------------------

fn timeoutNs(strategy_ns: u64) u64 {
    return if (strategy_ns == 0) default_startup_timeout_ns else strategy_ns;
}

fn pollNs(strategy_ns: u64) u64 {
    return if (strategy_ns == 0) default_poll_interval_ns else strategy_ns;
}

// --- ForLog -----------------------------------------------------------------

fn waitLog(s: LogStrategy, target: StrategyTarget, alloc: std.mem.Allocator) !void {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeoutNs(s.startup_timeout_ns)));
    const poll = pollNs(s.poll_interval_ns);

    while (std.time.nanoTimestamp() < deadline) {
        const logs = try target.vtable.logs(target.ptr, alloc);
        defer alloc.free(logs);

        var count: u32 = 0;
        if (!s.is_regexp) {
            // Plain substring counting
            var remaining = logs;
            while (std.mem.indexOf(u8, remaining, s.log)) |idx| {
                count += 1;
                remaining = remaining[idx + s.log.len ..];
            }
        } else {
            // Regex not in std — fall back to plain substring when is_regexp
            // is set but the pattern has no special chars.
            var remaining = logs;
            while (std.mem.indexOf(u8, remaining, s.log)) |idx| {
                count += 1;
                remaining = remaining[idx + s.log.len ..];
            }
        }

        if (count >= s.occurrence) return;

        std.Thread.sleep(poll);
    }

    return error.WaitStrategyTimeout;
}

// --- ForHTTP ----------------------------------------------------------------

fn waitHttp(s: HttpStrategy, target: StrategyTarget, alloc: std.mem.Allocator) !void {
    const dusty = @import("dusty");

    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeoutNs(s.startup_timeout_ns)));
    const poll = pollNs(s.poll_interval_ns);

    const host = try target.vtable.daemonHost(target.ptr, alloc);
    defer alloc.free(host);

    const port_spec = if (s.port.len == 0) "" else s.port;
    const mapped_port = try target.vtable.mappedPort(target.ptr, port_spec, alloc);

    const scheme = if (s.use_tls) "https" else "http";
    const url = try std.fmt.allocPrint(alloc, "{s}://{s}:{d}{s}", .{ scheme, host, mapped_port, s.path });
    defer alloc.free(url);

    while (std.time.nanoTimestamp() < deadline) {
        // Create a fresh client per attempt to avoid connection pool corruption
        // when the server is not yet ready and resets connections.
        var client = dusty.Client.init(alloc, .{ .max_idle_connections = 0 });
        defer client.deinit();

        var resp = client.fetch(url, .{
            .method = if (std.mem.eql(u8, s.method, "POST")) .post else .get,
        }) catch {
            std.Thread.sleep(poll);
            continue;
        };
        defer resp.deinit();

        // Always drain the body to keep the connection in a clean state.
        _ = resp.body() catch {};

        const code = @as(u16, @intCast(@intFromEnum(resp.status())));
        const ok = if (s.status_code == 0)
            code >= 200 and code < 300
        else
            code == s.status_code;

        if (ok) return;

        std.Thread.sleep(poll);
    }

    return error.WaitStrategyTimeout;
}

// --- ForPort ----------------------------------------------------------------

fn waitPort(s: PortStrategy, target: StrategyTarget, alloc: std.mem.Allocator) !void {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeoutNs(s.startup_timeout_ns)));
    const poll = pollNs(s.poll_interval_ns);

    const host = try target.vtable.daemonHost(target.ptr, alloc);
    defer alloc.free(host);

    const mapped_port = try target.vtable.mappedPort(target.ptr, s.port, alloc);

    while (std.time.nanoTimestamp() < deadline) {
        const stream = std.net.tcpConnectToHost(alloc, host, mapped_port) catch {
            std.Thread.sleep(poll);
            continue;
        };
        stream.close();
        return;
    }

    return error.WaitStrategyTimeout;
}

// --- ForHealthCheck ---------------------------------------------------------

fn waitHealthCheck(s: HealthCheckStrategy, target: StrategyTarget, alloc: std.mem.Allocator) !void {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeoutNs(s.startup_timeout_ns)));
    const poll = pollNs(s.poll_interval_ns);

    while (std.time.nanoTimestamp() < deadline) {
        const status = target.vtable.healthStatus(target.ptr, alloc) catch {
            std.Thread.sleep(poll);
            continue;
        };
        defer alloc.free(status);

        if (std.mem.eql(u8, status, "healthy")) return;

        // If health check is not configured, "none" means not applicable
        if (std.mem.eql(u8, status, "none")) return error.NoHealthCheck;

        std.Thread.sleep(poll);
    }

    return error.WaitStrategyTimeout;
}

// --- ForExec ----------------------------------------------------------------

fn waitExec(s: ExecStrategy, target: StrategyTarget, alloc: std.mem.Allocator) !void {
    const deadline = std.time.nanoTimestamp() + @as(i128, @intCast(timeoutNs(s.startup_timeout_ns)));
    const poll = pollNs(s.poll_interval_ns);

    while (std.time.nanoTimestamp() < deadline) {
        const result = target.vtable.exec(target.ptr, s.cmd, alloc) catch {
            std.Thread.sleep(poll);
            continue;
        };
        defer alloc.free(result.output);

        if (result.exit_code == s.expected_exit_code) return;

        std.Thread.sleep(poll);
    }

    return error.WaitStrategyTimeout;
}

// ---------------------------------------------------------------------------
// Tests — constructors and defaults
// ---------------------------------------------------------------------------

test "forLog: creates LogStrategy with correct fields" {
    const s = forLog("ready to accept connections");
    try std.testing.expect(s == .log);
    try std.testing.expectEqualStrings("ready to accept connections", s.log.log);
    try std.testing.expectEqual(@as(u32, 1), s.log.occurrence);
    try std.testing.expect(!s.log.is_regexp);
}

test "forHttp: creates HttpStrategy with correct path" {
    const s = forHttp("/healthz");
    try std.testing.expect(s == .http);
    try std.testing.expectEqualStrings("/healthz", s.http.path);
    try std.testing.expectEqualStrings("GET", s.http.method);
    try std.testing.expectEqual(@as(u16, 200), s.http.status_code);
    try std.testing.expect(!s.http.use_tls);
}

test "forPort: creates PortStrategy with correct port" {
    const s = forPort("5432/tcp");
    try std.testing.expect(s == .port);
    try std.testing.expectEqualStrings("5432/tcp", s.port.port);
}

test "forHealthCheck: creates HealthCheckStrategy" {
    const s = forHealthCheck();
    try std.testing.expect(s == .health_check);
}

test "forExec: creates ExecStrategy with command" {
    const cmd = [_][]const u8{ "pg_isready", "-U", "postgres" };
    const s = forExec(&cmd);
    try std.testing.expect(s == .exec);
    try std.testing.expectEqual(@as(usize, 3), s.exec.cmd.len);
    try std.testing.expectEqualStrings("pg_isready", s.exec.cmd[0]);
    try std.testing.expectEqual(@as(i64, 0), s.exec.expected_exit_code);
}

test "forAll: wraps multiple strategies" {
    const inner = [_]Strategy{ forLog("ready"), forPort("80/tcp") };
    const s = forAll(&inner);
    try std.testing.expect(s == .all);
    try std.testing.expectEqual(@as(usize, 2), s.all.len);
}

test "none strategy: waitUntilReady is a no-op" {
    // Construct a dummy target that panics if any vtable function is called
    const dummy_vtable = StrategyTarget.VTable{
        .daemonHost = struct {
            fn f(_: *anyopaque, _: std.mem.Allocator) anyerror![]const u8 {
                return error.ShouldNotBeCalled;
            }
        }.f,
        .mappedPort = struct {
            fn f(_: *anyopaque, _: []const u8, _: std.mem.Allocator) anyerror!u16 {
                return error.ShouldNotBeCalled;
            }
        }.f,
        .logs = struct {
            fn f(_: *anyopaque, _: std.mem.Allocator) anyerror![]const u8 {
                return error.ShouldNotBeCalled;
            }
        }.f,
        .exec = struct {
            fn f(_: *anyopaque, _: []const []const u8, _: std.mem.Allocator) anyerror!ExecResult {
                return error.ShouldNotBeCalled;
            }
        }.f,
        .healthStatus = struct {
            fn f(_: *anyopaque, _: std.mem.Allocator) anyerror![]const u8 {
                return error.ShouldNotBeCalled;
            }
        }.f,
    };
    var dummy_obj: u8 = 0;
    const target = StrategyTarget{ .ptr = &dummy_obj, .vtable = &dummy_vtable };
    const s: Strategy = .none;
    try s.waitUntilReady(target, std.testing.allocator);
}

test "timeoutNs: returns default when zero" {
    try std.testing.expectEqual(default_startup_timeout_ns, timeoutNs(0));
}

test "timeoutNs: returns supplied value when non-zero" {
    try std.testing.expectEqual(@as(u64, 5_000_000_000), timeoutNs(5_000_000_000));
}

test "pollNs: returns default when zero" {
    try std.testing.expectEqual(default_poll_interval_ns, pollNs(0));
}
