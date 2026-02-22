/// MongoDB module — mirrors testcontainers-go/modules/mongodb.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const mongo = try mongodb.run(&provider, mongodb.default_image, .{});
///   defer mongo.terminate() catch {};
///   defer mongo.deinit();
///
///   const uri = try mongo.connectionString(alloc);
///   defer alloc.free(uri);
///   // uri = "mongodb://localhost:PORT/" or "mongodb://user:pass@localhost:PORT/"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "mongo:7";
pub const default_port = "27017/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Optional root username.  Leave empty for no-auth mode.
    username: []const u8 = "",
    /// Optional root password.  Required when username is set.
    password: []const u8 = "",
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const MongoDBContainer = struct {
    container: *tc.DockerContainer,
    username: []const u8,
    password: []const u8,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *MongoDBContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *MongoDBContainer) void {
        self.container.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        self.allocator.destroy(self);
    }

    /// Returns the MongoDB connection URI.
    ///   No auth:   mongodb://host:port/
    ///   With auth: mongodb://user:pass@host:port/
    /// Caller owns the returned string.
    pub fn connectionString(self: *MongoDBContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        if (self.username.len > 0) {
            return std.fmt.allocPrint(allocator, "mongodb://{s}:{s}@{s}:{d}/", .{
                self.username, self.password, host, p,
            });
        }
        return std.fmt.allocPrint(allocator, "mongodb://{s}:{d}/", .{ host, p });
    }

    /// Returns the mapped host port.
    pub fn port(self: *MongoDBContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*MongoDBContainer {
    const alloc = provider.allocator;

    var env_list = std.ArrayList([]const u8).init(alloc);
    defer env_list.deinit();

    var user_env: ?[]const u8 = null;
    var pass_env: ?[]const u8 = null;
    if (opts.username.len > 0) {
        user_env = try std.fmt.allocPrint(alloc, "MONGO_INITDB_ROOT_USERNAME={s}", .{opts.username});
        pass_env = try std.fmt.allocPrint(alloc, "MONGO_INITDB_ROOT_PASSWORD={s}", .{opts.password});
        try env_list.append(user_env.?);
        try env_list.append(pass_env.?);
    }
    defer if (user_env) |e| alloc.free(e);
    defer if (pass_env) |e| alloc.free(e);

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{default_port},
        .env = env_list.items,
        .wait_strategy = tc.wait.forLog("Waiting for connections"),
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(MongoDBContainer);
    c.* = .{
        .container = docker_ctr,
        .username = try alloc.dupe(u8, opts.username),
        .password = try alloc.dupe(u8, opts.password),
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*MongoDBContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults — no auth" {
    const opts = Options{};
    try std.testing.expectEqualStrings("", opts.username);
    try std.testing.expectEqualStrings("", opts.password);
}
