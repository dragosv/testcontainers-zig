/// Postgres module — mirrors testcontainers-go/modules/postgres.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const pg = try postgres.run(&provider, postgres.default_image, .{});
///   defer pg.terminate() catch {};
///   defer pg.deinit();
///
///   const conn_str = try pg.connectionString(alloc);
///   defer alloc.free(conn_str);
///   // conn_str = "postgres://postgres:postgres@localhost:PORT/postgres"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "postgres:16-alpine";
pub const default_port = "5432/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    username: []const u8 = "postgres",
    password: []const u8 = "postgres",
    database: []const u8 = "postgres",
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const PostgresContainer = struct {
    container: *tc.DockerContainer,
    username: []const u8,
    password: []const u8,
    database: []const u8,
    allocator: std.mem.Allocator,

    /// Stop and remove the container.
    pub fn terminate(self: *PostgresContainer) !void {
        try self.container.terminate();
    }

    /// Free memory.  Does NOT stop the container — call terminate() first.
    pub fn deinit(self: *PostgresContainer) void {
        self.container.deinit();
        self.allocator.free(self.username);
        self.allocator.free(self.password);
        self.allocator.free(self.database);
        self.allocator.destroy(self);
    }

    /// Returns a libpq-compatible connection URL:
    ///   postgres://user:pass@host:mappedPort/database
    /// Caller owns the returned string.
    pub fn connectionString(self: *PostgresContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "postgres://{s}:{s}@{s}:{d}/{s}", .{
            self.username, self.password, host, p, self.database,
        });
    }

    /// Returns the mapped host port for the Postgres port.
    pub fn port(self: *PostgresContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

/// Run a Postgres container with the given image and options.
/// The container is started and ready to accept connections when this returns.
/// Caller must call terminate() then deinit() when done.
pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*PostgresContainer {
    const alloc = provider.allocator;

    const user_env = try std.fmt.allocPrint(alloc, "POSTGRES_USER={s}", .{opts.username});
    defer alloc.free(user_env);
    const pass_env = try std.fmt.allocPrint(alloc, "POSTGRES_PASSWORD={s}", .{opts.password});
    defer alloc.free(pass_env);
    const db_env = try std.fmt.allocPrint(alloc, "POSTGRES_DB={s}", .{opts.database});
    defer alloc.free(db_env);

    const envs = [_][]const u8{ user_env, pass_env, db_env };
    const cmd = [_][]const u8{ "postgres", "-c", "fsync=off" };

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{default_port},
        .env = &envs,
        .cmd = &cmd,
        .wait_strategy = tc.wait.forLog("database system is ready to accept connections"),
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(PostgresContainer);
    c.* = .{
        .container = docker_ctr,
        .username = try alloc.dupe(u8, opts.username),
        .password = try alloc.dupe(u8, opts.password),
        .database = try alloc.dupe(u8, opts.database),
        .allocator = alloc,
    };
    return c;
}

/// Run a Postgres container with default image and default options.
pub fn runDefault(provider: *tc.DockerProvider) !*PostgresContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("postgres", opts.username);
    try std.testing.expectEqualStrings("postgres", opts.password);
    try std.testing.expectEqualStrings("postgres", opts.database);
}
