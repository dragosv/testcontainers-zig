/// Docker Engine API JSON request and response types.
/// These map one-to-one with the Docker Engine REST API v1.41+.
const std = @import("std");

// ---------------------------------------------------------------------------
// Request bodies
// ---------------------------------------------------------------------------

/// A single port binding (maps a container port to a host port).
pub const PortBinding = struct {
    HostIp: []const u8 = "",
    HostPort: []const u8 = "",
};

/// Host configuration embedded in container create.
pub const HostConfig = struct {
    /// Map of "containerPort/proto" -> []PortBinding
    /// Serialised manually because keys are dynamic.
    /// Populated by ContainerCreateBody helpers.
    PortBindings: ?std.json.Value = null,
    NetworkMode: []const u8 = "default",
    Binds: ?[]const []const u8 = null,
    Privileged: bool = false,
    AutoRemove: bool = false,
};

// ---------------------------------------------------------------------------
// Response types (parsed from Docker API JSON)
// ---------------------------------------------------------------------------

/// Response from POST /containers/create
pub const ContainerCreateResponse = struct {
    Id: []const u8,
    Warnings: ?[]const []const u8 = null,
};

/// Compact container info from GET /containers/json
pub const ContainerListItem = struct {
    Id: []const u8,
    Names: ?[]const []const u8 = null,
    Image: []const u8,
    Status: []const u8,
    State: []const u8,
};

/// Container state returned inside inspect
pub const ContainerStateInfo = struct {
    Status: []const u8 = "",
    Running: bool = false,
    Paused: bool = false,
    Restarting: bool = false,
    OOMKilled: bool = false,
    Dead: bool = false,
    Pid: i64 = 0,
    ExitCode: i64 = 0,
    Error: []const u8 = "",
    StartedAt: []const u8 = "",
    FinishedAt: []const u8 = "",
    Health: ?ContainerHealthInfo = null,
};

/// Container health info (from HEALTHCHECK)
pub const ContainerHealthInfo = struct {
    Status: []const u8 = "",
};

/// Minimal inspect response from GET /containers/{id}/json
/// We use std.json.Value for the dynamic Ports map.
pub const ContainerInspect = struct {
    Id: []const u8,
    Name: []const u8,
    State: ContainerStateInfo,
    Config: ContainerConfig,
    NetworkSettings: NetworkSettings,
};

pub const ContainerConfig = struct {
    Image: []const u8 = "",
    Hostname: []const u8 = "",
};

pub const NetworkSettings = struct {
    IPAddress: []const u8 = "",
    Networks: ?std.json.Value = null,
    /// "containerPort/proto" -> [{HostIp, HostPort}]
    Ports: ?std.json.Value = null,
};

/// Response from POST /networks/create
pub const NetworkCreateResponse = struct {
    Id: []const u8,
    Warning: ?[]const u8 = null,
};

/// Exec create request body
pub const ExecCreateBody = struct {
    AttachStdout: bool = true,
    AttachStderr: bool = true,
    AttachStdin: bool = false,
    Tty: bool = false,
    Cmd: []const []const u8,
};

/// Response from POST /containers/{id}/exec
pub const ExecCreateResponse = struct {
    Id: []const u8,
};

/// Response from GET /exec/{id}/json
pub const ExecInspect = struct {
    ExitCode: i64 = 0,
    Running: bool = false,
};

/// Result returned from DockerClient.containerExec.
pub const ExecResult = struct {
    exit_code: i64,
    /// stdout+stderr combined; caller owns memory.
    output: []const u8,
};

/// Parsed mapped port: host-side IP and port number.
pub const MappedPort = struct {
    host_ip: []const u8,
    host_port: u16,
};

/// Extract the first host-port mapping for a given container port spec
/// (e.g. "80/tcp") from a NetworkSettings.Ports std.json.Value.
/// Returns null if not found or not mapped.
pub fn mappedPortFromJson(
    ports_value: std.json.Value,
    allocator: std.mem.Allocator,
    port_spec: []const u8,
) !?MappedPort {
    if (ports_value != .object) return null;
    const bindings = ports_value.object.get(port_spec) orelse return null;
    if (bindings == .null) return null;
    if (bindings != .array) return null;
    if (bindings.array.items.len == 0) return null;
    const first = bindings.array.items[0];
    if (first != .object) return null;

    const host_ip_v = first.object.get("HostIp") orelse return null;
    const host_port_v = first.object.get("HostPort") orelse return null;

    const host_ip = try allocator.dupe(u8, host_ip_v.string);
    const host_port_str = host_port_v.string;
    const host_port = std.fmt.parseInt(u16, host_port_str, 10) catch return null;

    return MappedPort{
        .host_ip = host_ip,
        .host_port = host_port,
    };
}

test "mappedPortFromJson returns expected port" {
    const allocator = std.testing.allocator;
    const json_str =
        \\{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"32768"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const mp = try mappedPortFromJson(parsed.value, allocator, "80/tcp");
    try std.testing.expect(mp != null);
    try std.testing.expectEqual(@as(u16, 32768), mp.?.host_port);
    allocator.free(mp.?.host_ip);
}
