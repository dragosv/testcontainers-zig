/// ContainerRequest and supporting types for configuring containers.
const std = @import("std");
const wait = @import("wait.zig");

// ---------------------------------------------------------------------------
// ContainerFile — a file to copy into the container at startup
// ---------------------------------------------------------------------------

pub const ContainerFile = struct {
    /// Path on the host to copy from. Ignored when `content` is set.
    host_path: ?[]const u8 = null,
    /// Raw bytes to write when host_path is null.
    content: ?[]const u8 = null,
    /// Absolute path inside the container.
    container_path: []const u8,
    /// File mode bits (e.g. 0o644).
    file_mode: u32 = 0o644,
};

// ---------------------------------------------------------------------------
// Mount — a volume or bind-mount
// ---------------------------------------------------------------------------

pub const MountType = enum { bind, volume, tmpfs };

pub const Mount = struct {
    mount_type: MountType = .bind,
    source: []const u8 = "",
    target: []const u8 = "",
    read_only: bool = false,
};

// ---------------------------------------------------------------------------
// ContainerRequest — the primary configuration object
// ---------------------------------------------------------------------------

/// Options for creating and starting a Docker container.
/// All slice fields are borrowed — the caller must keep them alive for the
/// duration of the `run` / `genericContainer` call.
pub const ContainerRequest = struct {
    /// Docker image reference, e.g. "nginx:latest" or "postgres:16-alpine".
    image: []const u8 = "",

    /// Command override (replaces the image default CMD).
    cmd: []const []const u8 = &.{},

    /// Entrypoint override.
    entrypoint: []const []const u8 = &.{},

    /// Environment variables as KEY=VALUE strings.
    env: []const []const u8 = &.{},

    /// Ports to expose from the container, e.g. "5432/tcp", "80".
    /// Each port may omit the "/tcp" suffix; it will be added automatically.
    exposed_ports: []const []const u8 = &.{},

    /// Arbitrary labels to apply to the container.
    labels: []const KV = &.{},

    /// Optional container name. Docker generates one if null.
    name: ?[]const u8 = null,

    /// Wait strategy executed after the container starts.
    /// Defaults to no waiting.
    wait_strategy: wait.Strategy = .none,

    /// Networks to attach the container to (by name or ID).
    networks: []const []const u8 = &.{},

    /// Network aliases per network, keyed by network name.
    network_aliases: []const NetworkAlias = &.{},

    /// Mounts (bind-mounts and named volumes).
    mounts: []const Mount = &.{},

    /// Files to copy into the container before it starts.
    files: []const ContainerFile = &.{},

    /// If true, always pull the image even if present locally.
    always_pull_image: bool = false,

    /// Image platform string (e.g. "linux/amd64").  Empty = Docker default.
    image_platform: []const u8 = "",

    /// Startup timeout in nanoseconds.  0 = use wait strategy default (60 s).
    startup_timeout_ns: u64 = 0,
};

/// A simple key-value pair used for labels.
pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// Per-network alias list.
pub const NetworkAlias = struct {
    network: []const u8,
    aliases: []const []const u8,
};

// ---------------------------------------------------------------------------
// GenericContainerRequest — wraps ContainerRequest with lifecycle options
// ---------------------------------------------------------------------------

pub const GenericContainerRequest = struct {
    /// The container configuration.
    container_request: ContainerRequest,
    /// Automatically start the container after creation. Default true.
    started: bool = true,
    /// Reuse an existing container with the same name if it exists.
    reuse: bool = false,
};

// ---------------------------------------------------------------------------
// TerminateOptions
// ---------------------------------------------------------------------------

pub const TerminateOptions = struct {
    /// Seconds to wait for graceful stop before force-killing.  Default 10.
    stop_timeout_seconds: i32 = 10,
    /// Remove anonymous volumes attached to the container.
    remove_volumes: bool = true,
};

// ---------------------------------------------------------------------------
// Normalize a port string to "port/tcp" format
// ---------------------------------------------------------------------------

/// The caller owns the returned string when an allocation was needed.
/// Returns the original slice unchanged when it already contains '/'.
pub fn normalizePort(allocator: std.mem.Allocator, port: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, port, '/') != null) return port;
    return std.fmt.allocPrint(allocator, "{s}/tcp", .{port});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "normalizePort: adds /tcp suffix when missing" {
    const result = try normalizePort(std.testing.allocator, "80");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("80/tcp", result);
}

test "normalizePort: keeps /tcp suffix unchanged" {
    // No allocation: input already has '/', original slice returned
    const result = try normalizePort(std.testing.allocator, "80/tcp");
    try std.testing.expectEqualStrings("80/tcp", result);
}

test "normalizePort: keeps /udp suffix unchanged" {
    const result = try normalizePort(std.testing.allocator, "53/udp");
    try std.testing.expectEqualStrings("53/udp", result);
}

test "normalizePort: numeric port without suffix gets /tcp" {
    const result = try normalizePort(std.testing.allocator, "5432");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("5432/tcp", result);
}

test "ContainerRequest: defaults are sensible" {
    const req = ContainerRequest{ .image = "alpine:3" };
    try std.testing.expectEqualStrings("alpine:3", req.image);
    try std.testing.expectEqual(@as(usize, 0), req.exposed_ports.len);
    try std.testing.expectEqual(@as(usize, 0), req.cmd.len);
    try std.testing.expect(req.name == null);
    try std.testing.expect(req.wait_strategy == .none);
}

test "GenericContainerRequest: reuse defaults to false" {
    const greq = GenericContainerRequest{
        .container_request = ContainerRequest{ .image = "alpine:3" },
    };
    try std.testing.expect(!greq.reuse);
    try std.testing.expect(greq.started);
}
