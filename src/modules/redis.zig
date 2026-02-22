/// Redis module — mirrors testcontainers-go/modules/redis.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const r = try redis.run(&provider, redis.default_image, .{});
///   defer r.terminate() catch {};
///   defer r.deinit();
///
///   const addr = try r.connectionString(alloc);
///   defer alloc.free(addr);
///   // addr = "redis://localhost:PORT"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "redis:7-alpine";
pub const default_port = "6379/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Optional password (requires AUTH).  Empty = no authentication.
    password: []const u8 = "",
    /// Additional redis.conf arguments passed to the server, e.g. "--save '' --appendonly no".
    extra_args: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const RedisContainer = struct {
    container: *tc.DockerContainer,
    password: []const u8,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *RedisContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *RedisContainer) void {
        self.container.deinit();
        self.allocator.free(self.password);
        self.allocator.destroy(self);
    }

    /// Returns the Redis connection URL: redis://[:password@]host:port
    /// Caller owns the returned string.
    pub fn connectionString(self: *RedisContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        if (self.password.len > 0) {
            return std.fmt.allocPrint(allocator, "redis://:{s}@{s}:{d}", .{
                self.password, host, p,
            });
        }
        return std.fmt.allocPrint(allocator, "redis://{s}:{d}", .{ host, p });
    }

    /// Returns the mapped host port.
    pub fn port(self: *RedisContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*RedisContainer {
    const alloc = provider.allocator;

    // Build command: [redis-server, --requirepass, PASSWORD, ...extra_args]
    var cmd_list = std.ArrayList([]const u8).init(alloc);
    defer cmd_list.deinit();
    try cmd_list.append("redis-server");
    if (opts.password.len > 0) {
        try cmd_list.append("--requirepass");
        try cmd_list.append(opts.password);
    }
    for (opts.extra_args) |arg| try cmd_list.append(arg);

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{default_port},
        .cmd = cmd_list.items,
        .wait_strategy = tc.wait.forLog("Ready to accept connections"),
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(RedisContainer);
    c.* = .{
        .container = docker_ctr,
        .password = try alloc.dupe(u8, opts.password),
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*RedisContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("", opts.password);
    try std.testing.expectEqual(@as(usize, 0), opts.extra_args.len);
}
