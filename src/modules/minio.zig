/// MinIO module — S3-compatible object storage.
/// Mirrors testcontainers-go/modules/minio.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const m = try minio.run(&provider, minio.default_image, .{});
///   defer m.terminate() catch {};
///   defer m.deinit();
///
///   const endpoint = try m.connectionString(alloc);
///   defer alloc.free(endpoint);
///   // endpoint = "http://localhost:PORT"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "minio/minio:RELEASE.2024-01-16T16-07-38Z";
pub const default_api_port = "9000/tcp";
pub const default_console_port = "9001/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    username: []const u8 = "minioadmin",
    password: []const u8 = "minioadmin",
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const MinIOContainer = struct {
    container: *tc.DockerContainer,
    /// Root user / access key.
    username: []const u8,
    /// Root password / secret key.
    password: []const u8,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *MinIOContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *MinIOContainer) void {
        self.container.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        self.allocator.destroy(self);
    }

    /// Returns the S3 API endpoint: http://host:port
    /// Use this as the endpoint_url for the AWS SDK / boto3 / minio client.
    /// Caller owns the returned string.
    pub fn connectionString(self: *MinIOContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_api_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, p });
    }

    /// Returns the mapped API port.
    pub fn apiPort(self: *MinIOContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_api_port, allocator);
    }

    /// Returns the mapped console port.
    pub fn consolePort(self: *MinIOContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_console_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*MinIOContainer {
    const alloc = provider.allocator;

    const user_env = try std.fmt.allocPrint(alloc, "MINIO_ROOT_USER={s}", .{opts.username});
    defer alloc.free(user_env);
    const pass_env = try std.fmt.allocPrint(alloc, "MINIO_ROOT_PASSWORD={s}", .{opts.password});
    defer alloc.free(pass_env);

    const envs = [_][]const u8{ user_env, pass_env };
    const cmd = [_][]const u8{ "server", "/data", "--console-address", ":9001" };

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{ default_api_port, default_console_port },
        .env = &envs,
        .cmd = &cmd,
        .wait_strategy = .{ .http = .{
            .path = "/minio/health/live",
            .port = default_api_port,
            .status_code = 200,
            .startup_timeout_ns = 60 * std.time.ns_per_s,
        } },
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(MinIOContainer);
    c.* = .{
        .container = docker_ctr,
        .username = try alloc.dupe(u8, opts.username),
        .password = try alloc.dupe(u8, opts.password),
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*MinIOContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("minioadmin", opts.username);
    try std.testing.expectEqualStrings("minioadmin", opts.password);
}
