/// MariaDB module — MySQL-compatible database.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const db = try mariadb.run(&provider, mariadb.default_image, .{});
///   defer db.terminate() catch {};
///   defer db.deinit();
///
///   const dsn = try db.connectionString(alloc);
///   defer alloc.free(dsn);
///   // dsn = "test:test@tcp(localhost:PORT)/test"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "mariadb:11";
pub const default_port = "3306/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    username: []const u8 = "test",
    password: []const u8 = "test",
    root_password: []const u8 = "root",
    database: []const u8 = "test",
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const MariaDBContainer = struct {
    container: *tc.DockerContainer,
    username: []const u8,
    password: []const u8,
    database: []const u8,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *MariaDBContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *MariaDBContainer) void {
        self.container.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
        self.allocator.destroy(self);
    }

    /// Returns a Go MySQL DSN: user:pass@tcp(host:port)/database
    /// Caller owns the returned string.
    pub fn connectionString(self: *MariaDBContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "{s}:{s}@tcp({s}:{d})/{s}", .{
            self.username, self.password, host, p, self.database,
        });
    }

    /// Returns the mapped host port.
    pub fn port(self: *MariaDBContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*MariaDBContainer {
    const alloc = provider.allocator;
    const is_root = std.mem.eql(u8, opts.username, "root");

    const root_pass_env = try std.fmt.allocPrint(alloc, "MARIADB_ROOT_PASSWORD={s}", .{opts.root_password});
    defer alloc.free(root_pass_env);
    const db_env = try std.fmt.allocPrint(alloc, "MARIADB_DATABASE={s}", .{opts.database});
    defer alloc.free(db_env);

    var env_list = std.ArrayList([]const u8).init(alloc);
    defer env_list.deinit();
    try env_list.append(root_pass_env);
    try env_list.append(db_env);

    var user_env: ?[]const u8 = null;
    var pass_env: ?[]const u8 = null;
    if (!is_root) {
        user_env = try std.fmt.allocPrint(alloc, "MARIADB_USER={s}", .{opts.username});
        pass_env = try std.fmt.allocPrint(alloc, "MARIADB_PASSWORD={s}", .{opts.password});
        try env_list.append(user_env.?);
        try env_list.append(pass_env.?);
    }
    defer if (user_env) |e| alloc.free(e);
    defer if (pass_env) |e| alloc.free(e);

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{default_port},
        .env = env_list.items,
        // MariaDB 11 logs "mariadbd: ready for connections." on startup
        .wait_strategy = tc.wait.forLog("mariadbd: ready for connections"),
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const actual_user = if (is_root) "root" else opts.username;
    const actual_pass = if (is_root) opts.root_password else opts.password;

    const c = try alloc.create(MariaDBContainer);
    c.* = .{
        .container = docker_ctr,
        .username = try alloc.dupe(u8, actual_user),
        .password = try alloc.dupe(u8, actual_pass),
        .database = try alloc.dupe(u8, opts.database),
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*MariaDBContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("test", opts.username);
    try std.testing.expectEqualStrings("test", opts.password);
    try std.testing.expectEqualStrings("test", opts.database);
}
