/// Network management — analogous to testcontainers-go's `network` package.
const std = @import("std");
const DockerClient = @import("docker_client.zig").DockerClient;
const container_mod = @import("container.zig");

// ---------------------------------------------------------------------------
// NetworkRequest
// ---------------------------------------------------------------------------

pub const NetworkRequest = struct {
    /// Network name. Required.
    name: []const u8,
    /// Network driver. Default "bridge".
    driver: []const u8 = "bridge",
    /// Arbitrary labels.
    labels: []const container_mod.KV = &.{},
    /// Internal network (no external connectivity).
    internal: bool = false,
    /// Allow manual container attachment.
    attachable: bool = true,
};

// ---------------------------------------------------------------------------
// DockerNetwork
// ---------------------------------------------------------------------------

pub const DockerNetwork = struct {
    /// Network ID.
    id: []const u8,
    /// Network name.
    name: []const u8,
    /// Driver.
    driver: []const u8,

    allocator: std.mem.Allocator,
    client: *DockerClient,

    /// Remove the network.
    pub fn remove(self: *DockerNetwork) !void {
        try self.client.networkRemove(self.id);
    }

    pub fn deinit(self: *DockerNetwork) void {
        self.allocator.free(self.id);
        self.allocator.free(self.name);
        self.allocator.free(self.driver);
        self.allocator.destroy(self);
    }
};

// ---------------------------------------------------------------------------
// Constructor
// ---------------------------------------------------------------------------

/// Create a new Docker network.
/// Caller must call `network.remove()` and `network.deinit()` when done.
pub fn newNetwork(
    allocator: std.mem.Allocator,
    client: *DockerClient,
    req: NetworkRequest,
) !*DockerNetwork {
    const id = try client.networkCreate(req.name, req.driver, req.labels);
    errdefer allocator.free(id);

    const net = try allocator.create(DockerNetwork);
    net.* = .{
        .id = id,
        .name = try allocator.dupe(u8, req.name),
        .driver = try allocator.dupe(u8, req.driver),
        .allocator = allocator,
        .client = client,
    };
    return net;
}
