/// Kafka module — uses bitnami/kafka in KRaft mode.
///
/// Quick start:
///
///   var provider = tc.DockerProvider.init(alloc);
///   defer provider.deinit();
///
///   const k = try kafka.run(&provider, kafka.default_image, .{});
///   defer k.terminate() catch {};
///   defer k.deinit();
///
///   const bootstrap = try k.brokers(alloc);
///   defer alloc.free(bootstrap);
///   // bootstrap = "localhost:PORT"
///
/// IMPORTANT — Advertised Listeners:
///   Kafka brokers advertise their address to clients via metadata responses.
///   By default this module configures KAFKA_CFG_ADVERTISED_LISTENERS to
///   "PLAINTEXT://localhost:9092" (the internal container port).
///   Clients connecting via the mapped Docker port will get the correct
///   bootstrap connection, but metadata refreshes may redirect to the internal
///   port (which is different from the mapped port on the host).
///
///   For reliable external access set `advertised_host` in Options to the
///   host's external IP and ensure a fixed host port is used (e.g. via a
///   custom docker run with -p 9092:9092).  For in-Docker-network testing
///   use the container name as advertised_host.
const std = @import("std");
const tc = @import("../root.zig");

// ---------------------------------------------------------------------------
// Defaults
// ---------------------------------------------------------------------------

pub const default_image = "bitnami/kafka:3.7";
pub const default_port = "9092/tcp";

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------

pub const Options = struct {
    /// The hostname/IP advertised to Kafka clients in metadata responses.
    /// For local host-based tests keep as "localhost".
    /// For cross-container (Docker network) tests use the container name/alias.
    advertised_host: []const u8 = "localhost",
    /// Allow automatic topic creation by producers/consumers.
    auto_create_topics: bool = true,
};

// ---------------------------------------------------------------------------
// Container type
// ---------------------------------------------------------------------------

pub const KafkaContainer = struct {
    container: *tc.DockerContainer,
    allocator: std.mem.Allocator,

    pub fn terminate(self: *KafkaContainer) !void {
        try self.container.terminate();
    }

    pub fn deinit(self: *KafkaContainer) void {
        self.container.deinit();
        self.allocator.destroy(self);
    }

    /// Returns "host:mappedPort" — use this as the bootstrap.servers value.
    /// Caller owns the returned string.
    pub fn brokers(self: *KafkaContainer, allocator: std.mem.Allocator) ![]const u8 {
        const p = try self.container.mappedPort(default_port, allocator);
        const host = try self.container.daemonHost(allocator);
        defer allocator.free(host);
        return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, p });
    }

    /// Returns the mapped host port.
    pub fn port(self: *KafkaContainer, allocator: std.mem.Allocator) !u16 {
        return self.container.mappedPort(default_port, allocator);
    }
};

// ---------------------------------------------------------------------------
// Factory
// ---------------------------------------------------------------------------

pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*KafkaContainer {
    const alloc = provider.allocator;

    // Build env list — bitnami/kafka uses KAFKA_CFG_* prefix for all options
    var env_list = std.ArrayList([]const u8).init(alloc);
    defer env_list.deinit();

    try env_list.append("KAFKA_CFG_NODE_ID=0");
    try env_list.append("KAFKA_CFG_PROCESS_ROLES=controller,broker");
    try env_list.append("KAFKA_CFG_CONTROLLER_QUORUM_VOTERS=0@localhost:9093");
    try env_list.append("KAFKA_CFG_LISTENERS=PLAINTEXT://:9092,CONTROLLER://:9093");

    const adv_env = try std.fmt.allocPrint(alloc, "KAFKA_CFG_ADVERTISED_LISTENERS=PLAINTEXT://{s}:9092", .{opts.advertised_host});
    defer alloc.free(adv_env);
    try env_list.append(adv_env);

    try env_list.append("KAFKA_CFG_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT");
    try env_list.append("KAFKA_CFG_CONTROLLER_LISTENER_NAMES=CONTROLLER");
    try env_list.append("KAFKA_CFG_INTER_BROKER_LISTENER_NAME=PLAINTEXT");
    try env_list.append("ALLOW_PLAINTEXT_LISTENER=yes");
    try env_list.append("KAFKA_CFG_OFFSETS_TOPIC_REPLICATION_FACTOR=1");
    try env_list.append("KAFKA_CFG_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1");
    try env_list.append("KAFKA_CFG_TRANSACTION_STATE_LOG_MIN_ISR=1");
    try env_list.append("KAFKA_CFG_GROUP_INITIAL_REBALANCE_DELAY_MS=0");

    const auto_create = if (opts.auto_create_topics) "true" else "false";
    const auto_create_env = try std.fmt.allocPrint(alloc, "KAFKA_CFG_AUTO_CREATE_TOPICS_ENABLE={s}", .{auto_create});
    defer alloc.free(auto_create_env);
    try env_list.append(auto_create_env);

    const req = tc.ContainerRequest{
        .image = image,
        .exposed_ports = &.{default_port},
        .env = env_list.items,
        .wait_strategy = tc.wait.forLog("Kafka Server started"),
    };

    const docker_ctr = try provider.runContainer(&req);
    errdefer {
        docker_ctr.terminate() catch {};
        docker_ctr.deinit();
    }

    const c = try alloc.create(KafkaContainer);
    c.* = .{
        .container = docker_ctr,
        .allocator = alloc,
    };
    return c;
}

pub fn runDefault(provider: *tc.DockerProvider) !*KafkaContainer {
    return run(provider, default_image, .{});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Options defaults" {
    const opts = Options{};
    try std.testing.expectEqualStrings("localhost", opts.advertised_host);
    try std.testing.expect(opts.auto_create_topics);
}
