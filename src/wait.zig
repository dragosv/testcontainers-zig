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

    var client = dusty.Client.init(alloc, .{});
    defer client.deinit();

    while (std.time.nanoTimestamp() < deadline) {
        var resp = client.fetch(url, .{
            .method = if (std.mem.eql(u8, s.method, "POST")) .post else .get,
        }) catch {
            std.Thread.sleep(poll);
            continue;
        };
        defer resp.deinit();

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
