/// Elasticsearch module — mirrors testcontainers-go/modules/elasticsearch.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   // For ES 8.x use xpack.security.enabled=false for unauthenticated access
///   const es = try elasticsearch.run(&provider, elasticsearch.default_image, .{
///       .password = "changeme",
///   });
///   defer es.terminate() catch {};
///   defer es.deinit();
///
///   const url = try es.httpURL(alloc);
///   defer alloc.free(url);
///   // url = "http://localhost:PORT"
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

/// Use 7.x for no-auth by default; for 8.x set password and disable xpack or
/// pass ELASTIC_PASSWORD + use HTTPS.
pub const default_image = "docker.elastic.co/elasticsearch/elasticsearch:8.12.0";
pub const default_http_port = "9200/tcp";
pub const default_transport_port = "9300/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// Password for the 'elastic' user (required for ES 8.x).
    /// Leave empty for ES 7.x (security disabled by default) or when you
    /// disable xpack security via extra_env.
    password: []const u8 = "changeme",
    /// Additional environment variables, e.g. {"xpack.security.enabled=false"}.
    extra_env: []const []const u8 = &.{},
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const ElasticsearchContainer = struct {
    container: *tc.DockerContainer,
    password: []const u8,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *ElasticsearchContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *ElasticsearchContainer) void {
        self.container.deinit();
        self.allocator.free(self.password);
        self.allocator.destroy(self);
    }

    /// Returns the HTTP endpoint: http://host:port
    /// Caller owns the returned string.
    pub fn httpURL(self: *ElasticsearchContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_http_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, p });
    }

    /// Returns the mapped HTTP port.
    pub fn port(self: *ElasticsearchContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_http_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*ElasticsearchContainer {
    const alloc = provider.allocator;

    var env_list = std.ArrayList([]const u8).init(alloc);
    defer env_list.deinit();

    // Core single-node config
    try env_list.append("discovery.type=single-node");
    try env_list.append("cluster.routing.allocation.disk.threshold_enabled=false");
    // Limit JVM heap for test environments
    try env_list.append("ES_JAVA_OPTS=-Xms1g -Xmx1g");

    var pass_env: ?[]const u8 = null;
    if (opts.password.len > 0) {
        pass_env = try std.fmt.allocPrint(alloc, "ELASTIC_PASSWORD={s}", .{opts.password});
        try env_list.append(pass_env.?);
    } else {
        // Disable security for 8.x when no password provided
        try env_list.append("xpack.security.enabled=false");
    }
    defer if (pass_env) |e| alloc.free(e);

    for (opts.extra_env) |e| try env_list.append(e);

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{ default_http_port, default_transport_port },
        .env = env_list.items,
        // Poll /_cat/health — returns 200 when cluster is green/yellow
        .wait_strategy = .{ .http = .{
            .path = "/_cat/health",
            .port = default_http_port,
            .status_code = 200,
            .startup_timeout_ns = 120 * std.time.ns_per_s,
        } },
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(ElasticsearchContainer);
    c.* = .{
        .container = docker_ctr,
        .password = try alloc.dupe(u8, opts.password),
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*ElasticsearchContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("changeme", opts.password);
}
