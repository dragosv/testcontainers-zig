/// MySQL module — mirrors testcontainers-go/modules/mysql.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const my = try mysql.run(&provider, mysql.default_image, .{});
///   defer my.terminate() catch {};
///   defer my.deinit();
///
///   const dsn = try my.connectionString(alloc);
///   defer alloc.free(dsn);
///   // dsn = "test:test@tcp(localhost:PORT)/test"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "mysql:8.0";
pub const default_port = "3306/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// MySQL user (non-root).  If set to "root", only root password is required.
    username: []const u8 = "test",
    password: []const u8 = "test",
    /// Root password.  Defaults to the same as password when username != "root".
    root_password: []const u8 = "root",
    database: []const u8 = "test",
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const MySQLContainer = struct {
    container: *tc.DockerContainer,
    username: []const u8,
    password: []const u8,
    database: []const u8,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *MySQLContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *MySQLContainer) void {
        self.container.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
        self.allocator.destroy(self);
    }

    /// Returns a Go MySQL DSN: user:pass@tcp(host:port)/database
    /// Caller owns the returned string.
    pub fn connectionString(self: *MySQLContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "{s}:{s}@tcp({s}:{d})/{s}", .{
            self.username, self.password, host, p, self.database,
        });
    }

    /// Returns the mapped host port.
    pub fn port(self: *MySQLContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*MySQLContainer {
    const alloc = provider.allocator;
    const is_root = std.mem.eql(u8, opts.username, "root");

    const root_pass_env = try std.fmt.allocPrint(alloc, "MYSQL_ROOT_PASSWORD={s}", .{opts.root_password});
    defer alloc.free(root_pass_env);
    const db_env = try std.fmt.allocPrint(alloc, "MYSQL_DATABASE={s}", .{opts.database});
    defer alloc.free(db_env);

    // Build env list — root user only needs MYSQL_ROOT_PASSWORD + MYSQL_DATABASE
    var env_list = std.ArrayList([]const u8).init(alloc);
    defer env_list.deinit();
    try env_list.append(root_pass_env);
    try env_list.append(db_env);

    var user_env: ?[]const u8 = null;
    var pass_env: ?[]const u8 = null;
    if (!is_root) {
        user_env = try std.fmt.allocPrint(alloc, "MYSQL_USER={s}", .{opts.username});
        pass_env = try std.fmt.allocPrint(alloc, "MYSQL_PASSWORD={s}", .{opts.password});
        try env_list.append(user_env.?);
        try env_list.append(pass_env.?);
    }
    defer if (user_env) |e| alloc.free(e);
    defer if (pass_env) |e| alloc.free(e);

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{default_port},
        .env = env_list.items,
        .wait_strategy = tc.wait.forLog("ready for connections"),
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const actual_user = if (is_root) "root" else opts.username;
    const actual_pass = if (is_root) opts.root_password else opts.password;

    const c = try alloc.create(MySQLContainer);
    c.* = .{
        .container = docker_ctr,
        .username = try alloc.dupe(u8, actual_user),
        .password = try alloc.dupe(u8, actual_pass),
        .database = try alloc.dupe(u8, opts.database),
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*MySQLContainer {
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
