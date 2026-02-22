/// DockerContainer — the concrete container object returned by `run()`.
///
/// Most methods inspect the running container via the Docker Engine API.
/// Memory is managed by an internal ArenaAllocator; call `deinit()` or
/// `terminate()` to release all resources.
const std = @import("std");
const types = @import("types.zig");
const wait = @import("wait.zig");
const container_mod = @import("container.zig");
const DockerClient = @import("docker_client.zig").DockerClient;

pub const DockerContainer = struct {
    /// Unique container ID (hex string).
    id: []const u8,
    /// Image used to create the container.
    image: []const u8,
    /// Whether the container is currently running.
    is_running: bool = false,

    // Internal
    allocator: std.mem.Allocator,
    client: *DockerClient,
    /// Wait strategy from the original ContainerRequest.
    wait_strategy: wait.Strategy,

    // -----------------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------------

    /// Start the container. Runs the wait strategy after Docker reports
    /// the container as started.
    pub fn start(self: *DockerContainer) !void {
        try self.client.containerStart(self.id);
        self.is_running = true;

        const target = self.strategyTarget();
        try self.wait_strategy.waitUntilReady(target, self.allocator);
    }

    /// Stop the container gracefully.  Pass null to use the Docker default
    /// stop timeout (10 s).
    pub fn stop(self: *DockerContainer, timeout_seconds: ?i32) !void {
        const t = timeout_seconds orelse 10;
        try self.client.containerStop(self.id, t);
        self.is_running = false;
    }

    /// Stop and remove the container (and its anonymous volumes).
    pub fn terminate(self: *DockerContainer) !void {
        try self.stop(null);
        try self.client.containerRemove(self.id, true, true);
        self.is_running = false;
    }

    /// Free the container handle.  Does NOT stop or remove the container.
    pub fn deinit(self: *DockerContainer) void {
        self.allocator.free(self.id);
        self.allocator.free(self.image);
        self.allocator.destroy(self);
    }

    // -----------------------------------------------------------------------
    // Inspection
    // -----------------------------------------------------------------------

    /// Return the Docker daemon host used to reach the container.
    /// On most setups this is "localhost"; respects DOCKER_HOST / TESTCONTAINERS_HOST_OVERRIDE.
    pub fn daemonHost(self: *DockerContainer, allocator: std.mem.Allocator) ![]const u8 {
        _ = self;
        // Respect overrides — std.posix.getenv does not allocate.
        if (std.posix.getenv("TESTCONTAINERS_HOST_OVERRIDE")) |h| {
            return allocator.dupe(u8, h);
        }
        if (std.posix.getenv("DOCKER_HOST")) |dh| {
            // e.g. "tcp://192.168.99.100:2376" → extract just the host
            if (std.mem.startsWith(u8, dh, "tcp://")) {
                const rest = dh[6..];
                const colon = std.mem.indexOfScalar(u8, rest, ':') orelse rest.len;
                return allocator.dupe(u8, rest[0..colon]);
            }
        }
        return allocator.dupe(u8, "localhost");
    }

    /// Return the host-mapped port for a container port spec (e.g. "80/tcp").
    /// When `port_spec` is empty, tries the first exposed port from the inspect.
    pub fn mappedPort(self: *DockerContainer, port_spec: []const u8, allocator: std.mem.Allocator) !u16 {
        var parsed = try self.client.containerInspect(self.id);
        defer parsed.deinit();

        const ports_val = parsed.value.NetworkSettings.Ports orelse
            return error.NoPortMapping;

        const spec = if (port_spec.len > 0) blk: {
            break :blk try container_mod.normalizePort(allocator, port_spec);
        } else blk: {
            // Find first key in the ports map
            if (ports_val != .object) return error.NoPortMapping;
            var it = ports_val.object.iterator();
            const entry = it.next() orelse return error.NoPortMapping;
            break :blk entry.key_ptr.*;
        };

        defer if (port_spec.len > 0 and std.mem.indexOfScalar(u8, port_spec, '/') == null)
            allocator.free(spec);

        const mp = try types.mappedPortFromJson(ports_val, allocator, spec) orelse
            return error.NoPortMapping;
        defer allocator.free(mp.host_ip);

        return mp.host_port;
    }

    /// Return the container IP address on the primary network.
    pub fn containerIP(self: *DockerContainer, allocator: std.mem.Allocator) ![]const u8 {
        var parsed = try self.client.containerInspect(self.id);
        defer parsed.deinit();
        return allocator.dupe(u8, parsed.value.NetworkSettings.IPAddress);
    }

    /// Return the names of networks the container is attached to.
    /// Caller owns the returned slice and each element string.
    /// Free with: `for (nets) |n| allocator.free(n); allocator.free(nets);`
    pub fn networks(self: *DockerContainer, allocator: std.mem.Allocator) ![][]const u8 {
        var parsed = try self.client.containerInspect(self.id);
        defer parsed.deinit();

        const nets_val = parsed.value.NetworkSettings.Networks orelse {
            const result = try allocator.alloc([]const u8, 0);
            return result;
        };
        if (nets_val != .object) {
            const result = try allocator.alloc([]const u8, 0);
            return result;
        }

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }
        var it = nets_val.object.iterator();
        while (it.next()) |entry| {
            try list.append(allocator, try allocator.dupe(u8, entry.key_ptr.*));
        }
        return list.toOwnedSlice(allocator);
    }

    /// Return aliases for a specific network this container is attached to.
    /// Returns an empty slice if the network has no aliases or the container
    /// is not on the network.
    /// Caller owns the returned slice and each element string.
    /// Free with: `for (aliases) |a| allocator.free(a); allocator.free(aliases);`
    pub fn networkAliases(
        self: *DockerContainer,
        network_name: []const u8,
        allocator: std.mem.Allocator,
    ) ![][]const u8 {
        var parsed = try self.client.containerInspect(self.id);
        defer parsed.deinit();

        const nets_val = parsed.value.NetworkSettings.Networks orelse
            return allocator.alloc([]const u8, 0);
        if (nets_val != .object) return allocator.alloc([]const u8, 0);

        const ep = nets_val.object.get(network_name) orelse
            return allocator.alloc([]const u8, 0);
        if (ep != .object) return allocator.alloc([]const u8, 0);

        const aliases_v = ep.object.get("Aliases") orelse
            return allocator.alloc([]const u8, 0);
        if (aliases_v != .array) return allocator.alloc([]const u8, 0);

        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |item| allocator.free(item);
            list.deinit(allocator);
        }
        for (aliases_v.array.items) |a| {
            if (a == .string) try list.append(allocator, try allocator.dupe(u8, a.string));
        }
        return list.toOwnedSlice(allocator);
    }

    /// Return the container IP address on the named network.
    pub fn networkIP(
        self: *DockerContainer,
        network_name: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        var parsed = try self.client.containerInspect(self.id);
        defer parsed.deinit();

        const nets_val = parsed.value.NetworkSettings.Networks orelse
            return error.NoNetwork;
        if (nets_val != .object) return error.NoNetwork;

        const ep = nets_val.object.get(network_name) orelse return error.NoNetwork;
        if (ep != .object) return error.NoNetwork;

        const ip_v = ep.object.get("IPAddress") orelse return error.NoNetwork;
        if (ip_v != .string) return error.NoNetwork;

        return allocator.dupe(u8, ip_v.string);
    }

    /// Return a host:port endpoint string for a container port.
    /// proto is prepended when non-empty (e.g. "http").
    pub fn endpoint(
        self: *DockerContainer,
        port_spec: []const u8,
        proto: []const u8,
        allocator: std.mem.Allocator,
    ) ![]const u8 {
        const host = try self.daemonHost(allocator);
        defer allocator.free(host);
        const port = try self.mappedPort(port_spec, allocator);

        if (proto.len == 0) {
            return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
        }
        return std.fmt.allocPrint(allocator, "{s}://{s}:{d}", .{ proto, host, port });
    }

    /// Inspect and return current state info.
    /// Caller must deinit the returned Parsed value.
    pub fn inspect(self: *DockerContainer) !std.json.Parsed(types.ContainerInspect) {
        return self.client.containerInspect(self.id);
    }

    /// Return the current state status string (e.g. "running", "exited").
    pub fn stateStatus(self: *DockerContainer, allocator: std.mem.Allocator) ![]const u8 {
        var parsed = try self.client.containerInspect(self.id);
        const result = try allocator.dupe(u8, parsed.value.State.Status);
        parsed.deinit();
        return result;
    }

    /// Return true if the container is currently running.
    pub fn isRunning(self: *DockerContainer) !bool {
        var parsed = try self.client.containerInspect(self.id);
        defer parsed.deinit();
        return parsed.value.State.Running;
    }

    // -----------------------------------------------------------------------
    // Logs
    // -----------------------------------------------------------------------

    /// Return all container logs (stdout + stderr) as a single string.
    /// Caller owns the returned memory (allocated via the container's allocator).
    pub fn logs(self: *DockerContainer) ![]const u8 {
        return self.client.containerLogs(self.id);
    }

    // -----------------------------------------------------------------------
    // Exec
    // -----------------------------------------------------------------------

    /// Run a command inside the container. Returns exit code and output.
    /// Caller owns `result.output`.
    pub fn exec(
        self: *DockerContainer,
        cmd: []const []const u8,
    ) !types.ExecResult {
        return self.client.containerExec(self.id, cmd);
    }

    // -----------------------------------------------------------------------
    // File copy
    // -----------------------------------------------------------------------

    /// Copy bytes into the container at `container_path`.
    /// The path must be an absolute path to an existing *directory* inside
    /// the container; the filename is taken from the last component.
    pub fn copyToContainer(
        self: *DockerContainer,
        content: []const u8,
        container_path: []const u8,
        file_mode: u32,
    ) !void {
        _ = file_mode;
        // Build a minimal tar archive in memory and POST it to
        // PUT /containers/{id}/archive?path=<dir>

        const dir = std.fs.path.dirname(container_path) orelse "/";
        const filename = std.fs.path.basename(container_path);

        var tar_buf: std.ArrayList(u8) = .empty;
        defer tar_buf.deinit(self.allocator);

        try writeTarEntry(self.allocator, &tar_buf, filename, content);

        try self.client.containerPutArchive(self.id, dir, tar_buf.items);
    }

    // -----------------------------------------------------------------------
    // Wait strategy integration (vtable)
    // -----------------------------------------------------------------------

    fn strategyTarget(self: *DockerContainer) wait.StrategyTarget {
        return .{
            .ptr = self,
            .vtable = &vtable_impl,
        };
    }

    const vtable_impl = wait.StrategyTarget.VTable{
        .daemonHost = vtDaemonHost,
        .mappedPort = vtMappedPort,
        .logs = vtLogs,
        .exec = vtExec,
        .healthStatus = vtHealthStatus,
    };

    fn vtDaemonHost(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        const self: *DockerContainer = @ptrCast(@alignCast(ptr));
        return self.daemonHost(alloc);
    }

    fn vtMappedPort(ptr: *anyopaque, port_spec: []const u8, alloc: std.mem.Allocator) anyerror!u16 {
        const self: *DockerContainer = @ptrCast(@alignCast(ptr));
        return self.mappedPort(port_spec, alloc);
    }

    fn vtLogs(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        _ = alloc;
        const self: *DockerContainer = @ptrCast(@alignCast(ptr));
        return self.client.containerLogs(self.id);
    }

    fn vtExec(ptr: *anyopaque, cmd: []const []const u8, alloc: std.mem.Allocator) anyerror!wait.ExecResult {
        _ = alloc;
        const self: *DockerContainer = @ptrCast(@alignCast(ptr));
        const result = try self.client.containerExec(self.id, cmd);
        return wait.ExecResult{
            .exit_code = result.exit_code,
            .output = result.output,
        };
    }

    fn vtHealthStatus(ptr: *anyopaque, alloc: std.mem.Allocator) anyerror![]const u8 {
        const self: *DockerContainer = @ptrCast(@alignCast(ptr));
        var parsed = try self.client.containerInspect(self.id);
        defer parsed.deinit();
        const health = parsed.value.State.Health orelse
            return alloc.dupe(u8, "none");
        return alloc.dupe(u8, health.Status);
    }
};

// ---------------------------------------------------------------------------
// Minimal TAR writer (POSIX ustar) for copyToContainer
// ---------------------------------------------------------------------------

fn writeTarEntry(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), filename: []const u8, content: []const u8) !void {
    var header: [512]u8 = std.mem.zeroes([512]u8);

    // name (100 bytes)
    const name_len = @min(filename.len, 99);
    @memcpy(header[0..name_len], filename[0..name_len]);

    // mode (8 bytes)
    _ = try std.fmt.bufPrint(header[100..107], "{o:0>7}", .{@as(u32, 0o644)});
    header[107] = ' ';

    // uid, gid (8 bytes each)
    _ = try std.fmt.bufPrint(header[108..115], "{o:0>7}", .{@as(u32, 0)});
    header[115] = ' ';
    _ = try std.fmt.bufPrint(header[116..123], "{o:0>7}", .{@as(u32, 0)});
    header[123] = ' ';

    // size (12 bytes)
    _ = try std.fmt.bufPrint(header[124..135], "{o:0>11}", .{content.len});
    header[135] = ' ';

    // mtime (12 bytes) — zero
    @memset(header[136..147], '0');
    header[147] = ' ';

    // typeflag = '0' (regular file)
    header[156] = '0';

    // magic "ustar  "
    @memcpy(header[257..264], "ustar  ");

    // checksum placeholder
    @memset(header[148..156], ' ');
    var checksum: u32 = 0;
    for (header) |b| checksum += b;
    _ = try std.fmt.bufPrint(header[148..155], "{o:0>6}", .{checksum});
    header[155] = 0;
    header[156] = ' ';

    try buf.appendSlice(allocator, &header);
    try buf.appendSlice(allocator, content);

    // Pad to 512-byte boundary
    const remainder = content.len % 512;
    if (remainder != 0) {
        const padding = 512 - remainder;
        try buf.appendNTimes(allocator, 0, padding);
    }

    // Two zero blocks at end
    try buf.appendNTimes(allocator, 0, 1024);
}

fn percentEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '_' or c == '.') {
            try out.append(allocator, c);
        } else {
            var hex_buf: [3]u8 = undefined;
            const hex = try std.fmt.bufPrint(&hex_buf, "%{X:0>2}", .{c});
            try out.appendSlice(allocator, hex);
        }
    }
    return out.toOwnedSlice(allocator);
}
