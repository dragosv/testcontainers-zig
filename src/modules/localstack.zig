/// LocalStack module — AWS service mocking.
/// Mirrors testcontainers-go/modules/localstack.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const ls = try localstack.run(&provider, localstack.default_image, .{});
///   defer ls.terminate() catch {};
///   defer ls.deinit();
///
///   const endpoint = try ls.endpointURL(alloc);
///   defer alloc.free(endpoint);
///   // endpoint = "http://localhost:PORT"
///
///   // Then configure AWS SDK:
///   // endpoint_url = endpoint
///   // region = "us-east-1"
///   // access_key_id = "test"
///   // secret_access_key = "test"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "localstack/localstack:3";
pub const default_port = "4566/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Comma-separated list of services to enable, e.g. "s3,sqs,dynamodb".
    /// Leave empty to enable all services (default LocalStack behaviour).
    services: []const u8 = "",
    /// Set DEBUG=1 for verbose LocalStack output.
    debug: bool = false,
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const LocalStackContainer = struct {
    container: *tc.DockerContainer,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *LocalStackContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *LocalStackContainer) void {
        self.container.deinit();
        self.allocator.destroy(self);
    }

    /// Returns the LocalStack endpoint URL: http://host:port
    /// Pass this as `endpoint_url` to any AWS SDK client.
    /// Caller owns the returned string.
    pub fn endpointURL(self: *LocalStackContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, p });
    }

    /// Returns the mapped host port.
    pub fn port(self: *LocalStackContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*LocalStackContainer {
    const alloc = provider.allocator;

    var env_list = std.ArrayList([]const u8).init(alloc);
    defer env_list.deinit();

    if (opts.services.len > 0) {
        const svc_env = try std.fmt.allocPrint(alloc, "SERVICES={s}", .{opts.services});
        defer alloc.free(svc_env);
        try env_list.append(svc_env);
    }

    if (opts.debug) {
        try env_list.append("DEBUG=1");
    }

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{default_port},
        .env = env_list.items,
        .wait_strategy = .{ .http = .{
            .path = "/_localstack/health",
            .port = default_port,
            .status_code = 200,
            .startup_timeout_ns = 120 * std.time.ns_per_s,
        } },
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(LocalStackContainer);
    c.* = .{
        .container = docker_ctr,
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*LocalStackContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("", opts.services);
    try std.testing.expect(!opts.debug);
}
