/// RabbitMQ module — mirrors testcontainers-go/modules/rabbitmq.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const rmq = try rabbitmq.run(&provider, rabbitmq.default_image, .{});
///   defer rmq.terminate() catch {};
///   defer rmq.deinit();
///
///   const amqp_url = try rmq.amqpURL(alloc);
///   defer alloc.free(amqp_url);
///   // amqp_url = "amqp://guest:guest@localhost:PORT"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "rabbitmq:3-management-alpine";
pub const default_amqp_port = "5672/tcp";
pub const default_mgmt_port = "15672/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    username: []const u8 = "guest",
    password: []const u8 = "guest",
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const RabbitMQContainer = struct {
    container: *tc.DockerContainer,
    username: []const u8,
    password: []const u8,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *RabbitMQContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *RabbitMQContainer) void {
        self.container.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        self.allocator.destroy(self);
    }

    /// Returns the AMQP connection URL: amqp://user:pass@host:port
    /// Caller owns the returned string.
    pub fn amqpURL(self: *RabbitMQContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_amqp_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "amqp://{s}:{s}@{s}:{d}", .{
            self.username, self.password, host, p,
        });
    }

    /// Returns the HTTP management console URL: http://host:port
    /// Caller owns the returned string.
    pub fn httpURL(self: *RabbitMQContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_mgmt_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, p });
    }

    /// Returns the mapped AMQP port.
    pub fn amqpPort(self: *RabbitMQContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_amqp_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*RabbitMQContainer {
    const alloc = provider.allocator;

    const user_env = try std.fmt.allocPrint(alloc, "RABBITMQ_DEFAULT_USER={s}", .{opts.username});
    defer alloc.free(user_env);
    const pass_env = try std.fmt.allocPrint(alloc, "RABBITMQ_DEFAULT_PASS={s}", .{opts.password});
    defer alloc.free(pass_env);

    const envs = [_][]const u8{ user_env, pass_env };

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{ default_amqp_port, default_mgmt_port },
        .env = &envs,
        .wait_strategy = tc.wait.forLog("Server startup complete"),
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(RabbitMQContainer);
    c.* = .{
        .container = docker_ctr,
        .username = try alloc.dupe(u8, opts.username),
        .password = try alloc.dupe(u8, opts.password),
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*RabbitMQContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("guest", opts.username);
    try std.testing.expectEqualStrings("guest", opts.password);
}
