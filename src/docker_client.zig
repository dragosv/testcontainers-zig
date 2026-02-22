/// DockerClient — thin wrapper around dusty's HTTP client using Unix sockets
/// to communicate with the Docker Engine REST API.
///
/// All responses are allocated with the caller-supplied allocator; the caller
/// is responsible for freeing them unless documented otherwise.
///
/// IMPORTANT: A `zio.Runtime` must be initialised on the calling thread before
/// creating a DockerClient or calling any of its methods, because dusty's
/// networking is driven by the zio event loop.
const std = @import("std");
const dusty = @import("dusty");
const types = @import("types.zig");
const container_mod = @import("container.zig");

/// Default Docker socket path.
pub const docker_socket = "/var/run/docker.sock";

/// Docker Engine API version used for all requests.
pub const api_version = "v1.46";

pub const DockerClientError = error{
    ApiError,
    NotFound,
    Conflict,
    ServerError,
    InvalidResponse,
};

/// Lightweight Docker HTTP client backed by a Unix domain socket.
pub const DockerClient = struct {
    allocator: std.mem.Allocator,
    socket_path: []const u8,
    client: dusty.Client,

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) DockerClient {
        return .{
            .allocator = allocator,
            .socket_path = socket_path,
            .client = dusty.Client.init(allocator, .{
                // Allow large response bodies (e.g. logs, inspect output)
                .max_response_size = 64 * 1024 * 1024,
            }),
        };
    }

    pub fn deinit(self: *DockerClient) void {
        self.client.deinit();
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Build the full URL for a Docker API path.
    fn apiUrl(self: *DockerClient, path: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "http://localhost{s}", .{path});
    }

    /// Perform a request and check that the status code is acceptable.
    /// Returns the raw body bytes (caller owns the memory).
    fn doRequest(
        self: *DockerClient,
        method: dusty.Method,
        path: []const u8,
        body: ?[]const u8,
        content_type: ?[]const u8,
        expected_codes: []const u16,
    ) ![]const u8 {
        const url = try self.apiUrl(path);
        defer self.allocator.free(url);

        var headers: dusty.Headers = .{};
        defer headers.deinit(self.allocator);
        if (content_type) |ct| {
            try headers.put(self.allocator, "Content-Type", ct);
        }

        var resp = try self.client.fetch(url, .{
            .method = method,
            .body = body,
            .unix_socket_path = self.socket_path,
            .headers = if (content_type != null) &headers else null,
        });
        defer resp.deinit();

        const sc: u16 = @as(u16, @intCast(@intFromEnum(resp.status())));

        var acceptable = false;
        for (expected_codes) |c| {
            if (c == sc) {
                acceptable = true;
                break;
            }
        }

        if (!acceptable) {
            // Drain the response body so the connection can be safely reused.
            // Skipping this leaves unread bytes on the socket which would corrupt
            // the next request parsed over the same keep-alive connection.
            _ = resp.body() catch {};
            if (sc == 404) return DockerClientError.NotFound;
            if (sc == 409) return DockerClientError.Conflict;
            if (sc >= 500) return DockerClientError.ServerError;
            return DockerClientError.ApiError;
        }

        const resp_body = try resp.body() orelse "";
        return self.allocator.dupe(u8, resp_body);
    }

    // -----------------------------------------------------------------------
    // Image operations
    // -----------------------------------------------------------------------

    /// Pull an image. Blocks until the pull is complete.
    /// image_ref should be "name:tag" or "name" (defaults to latest).
    pub fn imagePull(self: *DockerClient, image_ref: []const u8) !void {
        // Split "name:tag" or "name@digest"
        var name: []const u8 = image_ref;
        var tag: []const u8 = "latest";

        if (std.mem.lastIndexOfScalar(u8, image_ref, ':')) |colon_idx| {
            // Make sure it's not a registry port (no slash after the colon)
            const after = image_ref[colon_idx + 1 ..];
            if (std.mem.indexOfScalar(u8, after, '/') == null) {
                name = image_ref[0..colon_idx];
                tag = after;
            }
        }

        const encoded_name = try uriEncode(self.allocator, name);
        defer self.allocator.free(encoded_name);
        const encoded_tag = try uriEncode(self.allocator, tag);
        defer self.allocator.free(encoded_tag);

        const api_path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/images/create?fromImage={s}&tag={s}",
            .{ api_version, encoded_name, encoded_tag },
        );
        defer self.allocator.free(api_path);

        const url = try self.apiUrl(api_path);
        defer self.allocator.free(url);

        // imagePull returns a streaming JSON progress response.
        // We use a streaming reader to drain it without buffering the whole body,
        // which avoids hitting max_response_size for large image pulls.
        var resp = try self.client.fetch(url, .{
            .method = .post,
            .unix_socket_path = self.socket_path,
            .decompress = false,
        });
        defer resp.deinit();

        const sc: u16 = @as(u16, @intCast(@intFromEnum(resp.status())));
        if (sc != 200) return DockerClientError.ApiError;

        // Drain the progress stream to wait for completion.
        const r = resp.reader();
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = r.readSliceShort(&buf) catch break;
            if (n == 0) break;
        }
    }

    /// Check if an image exists locally. Returns true if found.
    pub fn imageExists(self: *DockerClient, image_ref: []const u8) !bool {
        const encoded = try uriEncode(self.allocator, image_ref);
        defer self.allocator.free(encoded);

        const api_path = try std.fmt.allocPrint(self.allocator, "/{s}/images/{s}/json", .{ api_version, encoded });
        defer self.allocator.free(api_path);

        const body = self.doRequest(.get, api_path, null, null, &.{200}) catch |err| {
            if (err == DockerClientError.NotFound) return false;
            return err;
        };
        self.allocator.free(body);
        return true;
    }

    // -----------------------------------------------------------------------
    // Container operations
    // -----------------------------------------------------------------------

    /// Create a container. Returns the new container ID.
    pub fn containerCreate(
        self: *DockerClient,
        req: *const container_mod.ContainerRequest,
        name: ?[]const u8,
    ) ![]const u8 {
        // Build JSON body using std.json.Value
        const body_json = try buildCreateBody(self.allocator, req);
        defer self.allocator.free(body_json);

        var path_buf: [256]u8 = undefined;
        const api_path = if (name) |n|
            try std.fmt.allocPrint(self.allocator, "/{s}/containers/create?name={s}", .{ api_version, n })
        else
            try std.fmt.bufPrint(&path_buf, "/{s}/containers/create", .{api_version});
        defer if (name != null) self.allocator.free(api_path);

        const resp_body = try self.doRequest(.post, api_path, body_json, "application/json", &.{201});
        defer self.allocator.free(resp_body);

        var parsed = try std.json.parseFromSlice(
            types.ContainerCreateResponse,
            self.allocator,
            resp_body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        return self.allocator.dupe(u8, parsed.value.Id);
    }

    /// Start a container by ID.
    pub fn containerStart(self: *DockerClient, id: []const u8) !void {
        const api_path = try std.fmt.allocPrint(self.allocator, "/{s}/containers/{s}/start", .{ api_version, id });
        defer self.allocator.free(api_path);
        const body = try self.doRequest(.post, api_path, null, null, &.{ 204, 304 });
        self.allocator.free(body);
    }

    /// Stop a container.  timeout_seconds < 0 means no kill timeout.
    pub fn containerStop(self: *DockerClient, id: []const u8, timeout_seconds: i32) !void {
        const api_path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/containers/{s}/stop?t={d}",
            .{ api_version, id, timeout_seconds },
        );
        defer self.allocator.free(api_path);

        const body = self.doRequest(.post, api_path, null, null, &.{ 204, 304 }) catch |err| {
            if (err == DockerClientError.NotFound) return; // already gone
            return err;
        };
        self.allocator.free(body);
    }

    /// Remove a container.
    pub fn containerRemove(
        self: *DockerClient,
        id: []const u8,
        force: bool,
        remove_volumes: bool,
    ) !void {
        const api_path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/containers/{s}?force={s}&v={s}",
            .{
                api_version,
                id,
                if (force) "true" else "false",
                if (remove_volumes) "true" else "false",
            },
        );
        defer self.allocator.free(api_path);

        const body = self.doRequest(.delete, api_path, null, null, &.{204}) catch |err| {
            if (err == DockerClientError.NotFound) return;
            return err;
        };
        self.allocator.free(body);
    }

    /// Inspect a container. Caller owns the returned JSON bytes.
    pub fn containerInspectRaw(self: *DockerClient, id: []const u8) ![]const u8 {
        const api_path = try std.fmt.allocPrint(self.allocator, "/{s}/containers/{s}/json", .{ api_version, id });
        defer self.allocator.free(api_path);
        return self.doRequest(.get, api_path, null, null, &.{200});
    }

    /// Returns the parsed inspect structure. The caller must call `.deinit()`
    /// on the returned `Parsed(T)` to free the JSON arena.
    pub fn containerInspect(
        self: *DockerClient,
        id: []const u8,
    ) !std.json.Parsed(types.ContainerInspect) {
        const raw = try self.containerInspectRaw(id);
        defer self.allocator.free(raw);
        // Use alloc_always to force all strings to be copied into the arena
        // rather than storing zero-copy slices into the temporary `raw` buffer.
        return std.json.parseFromSlice(
            types.ContainerInspect,
            self.allocator,
            raw,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    /// Fetch container logs (stdout + stderr).
    /// Returns raw multiplexed stream bytes; caller owns memory.
    pub fn containerLogsRaw(self: *DockerClient, id: []const u8) ![]const u8 {
        const api_path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/containers/{s}/logs?stdout=1&stderr=1&timestamps=0",
            .{ api_version, id },
        );
        defer self.allocator.free(api_path);
        return self.doRequest(.get, api_path, null, null, &.{200});
    }

    /// Decode Docker multiplexed log stream into plain text.
    /// Docker log frames: [type(1), 0,0,0, size(4 BE)] + data.
    pub fn decodeLogs(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var pos: usize = 0;
        while (pos + 8 <= raw.len) {
            // stream_type = raw[pos] (1=stdout, 2=stderr; we accept both)
            const size: u32 = @as(u32, raw[pos + 4]) << 24 |
                @as(u32, raw[pos + 5]) << 16 |
                @as(u32, raw[pos + 6]) << 8 |
                @as(u32, raw[pos + 7]);
            pos += 8;
            const end = pos + size;
            if (end > raw.len) break;
            try out.appendSlice(allocator, raw[pos..end]);
            pos = end;
        }

        return out.toOwnedSlice(allocator);
    }

    /// Convenience: fetch and decode container logs.
    pub fn containerLogs(self: *DockerClient, id: []const u8) ![]const u8 {
        const raw = try self.containerLogsRaw(id);
        defer self.allocator.free(raw);
        return decodeLogs(self.allocator, raw);
    }

    // -----------------------------------------------------------------------
    // Exec
    // -----------------------------------------------------------------------

    /// Run a command inside a container; wait for it to finish.
    /// Returns the exit code and captured stdout+stderr output.
    pub fn containerExec(
        self: *DockerClient,
        id: []const u8,
        cmd: []const []const u8,
    ) !types.ExecResult {
        // 1. Create exec instance
        const create_body = try buildExecCreateBody(self.allocator, cmd);
        defer self.allocator.free(create_body);

        const create_api_path = try std.fmt.allocPrint(self.allocator, "/{s}/containers/{s}/exec", .{ api_version, id });
        defer self.allocator.free(create_api_path);

        const create_resp = try self.doRequest(.post, create_api_path, create_body, "application/json", &.{201});
        defer self.allocator.free(create_resp);

        var parsed_exec = try std.json.parseFromSlice(
            types.ExecCreateResponse,
            self.allocator,
            create_resp,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed_exec.deinit();

        const exec_id = try self.allocator.dupe(u8, parsed_exec.value.Id);
        defer self.allocator.free(exec_id);

        // 2. Start exec (detach=false to capture output)
        const start_body =
            \\{"Detach":false,"Tty":false}
        ;
        const start_api_path = try std.fmt.allocPrint(self.allocator, "/{s}/exec/{s}/start", .{ api_version, exec_id });
        defer self.allocator.free(start_api_path);

        const raw_output = try self.doRequest(.post, start_api_path, start_body, "application/json", &.{200});
        defer self.allocator.free(raw_output);

        const output = try decodeLogs(self.allocator, raw_output);

        // 3. Inspect exec to get exit code
        const inspect_api_path = try std.fmt.allocPrint(self.allocator, "/{s}/exec/{s}/json", .{ api_version, exec_id });
        defer self.allocator.free(inspect_api_path);

        const inspect_body = try self.doRequest(.get, inspect_api_path, null, null, &.{200});
        defer self.allocator.free(inspect_body);

        var parsed_inspect = try std.json.parseFromSlice(
            types.ExecInspect,
            self.allocator,
            inspect_body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed_inspect.deinit();

        return types.ExecResult{
            .exit_code = parsed_inspect.value.ExitCode,
            .output = output,
        };
    }

    // -----------------------------------------------------------------------
    // Network operations
    // -----------------------------------------------------------------------

    /// Create a Docker network; return its ID.
    pub fn networkCreate(
        self: *DockerClient,
        name: []const u8,
        driver: []const u8,
        labels: []const container_mod.KV,
    ) ![]const u8 {
        const body = try buildNetworkCreateBody(self.allocator, name, driver, labels);
        defer self.allocator.free(body);

        var api_path_buf: [64]u8 = undefined;
        const api_path = try std.fmt.bufPrint(&api_path_buf, "/{s}/networks/create", .{api_version});

        const resp_body = try self.doRequest(.post, api_path, body, "application/json", &.{201});
        defer self.allocator.free(resp_body);

        var parsed = try std.json.parseFromSlice(
            types.NetworkCreateResponse,
            self.allocator,
            resp_body,
            .{ .ignore_unknown_fields = true },
        );
        defer parsed.deinit();

        return self.allocator.dupe(u8, parsed.value.Id);
    }

    /// Remove a Docker network by ID.
    pub fn networkRemove(self: *DockerClient, id: []const u8) !void {
        const api_path = try std.fmt.allocPrint(self.allocator, "/{s}/networks/{s}", .{ api_version, id });
        defer self.allocator.free(api_path);

        const body = self.doRequest(.delete, api_path, null, null, &.{204}) catch |err| {
            if (err == DockerClientError.NotFound) return;
            return err;
        };
        self.allocator.free(body);
    }

    /// Connect a container to a network with optional aliases.
    pub fn networkConnect(
        self: *DockerClient,
        network_id: []const u8,
        container_id: []const u8,
        aliases: []const []const u8,
    ) !void {
        const body = try buildNetworkConnectBody(self.allocator, container_id, aliases);
        defer self.allocator.free(body);

        const api_path = try std.fmt.allocPrint(self.allocator, "/{s}/networks/{s}/connect", .{ api_version, network_id });
        defer self.allocator.free(api_path);

        const resp = try self.doRequest(.post, api_path, body, "application/json", &.{200});
        self.allocator.free(resp);
    }

    /// Upload a tar archive to a container path.
    /// Used by DockerContainer.copyToContainer.
    pub fn containerPutArchive(
        self: *DockerClient,
        id: []const u8,
        path: []const u8,
        tar_data: []const u8,
    ) !void {
        const encoded = try uriEncode(self.allocator, path);
        defer self.allocator.free(encoded);
        const api_path = try std.fmt.allocPrint(
            self.allocator,
            "/{s}/containers/{s}/archive?path={s}",
            .{ api_version, id, encoded },
        );
        defer self.allocator.free(api_path);
        const body = try self.doRequest(.put, api_path, tar_data, "application/x-tar", &.{200});
        self.allocator.free(body);
    }

    // -----------------------------------------------------------------------
    // Container discovery
    // -----------------------------------------------------------------------

    /// Look up a container by exact name. Returns the container ID if found,
    /// or null if no container with that name exists.
    /// Caller owns the returned string.
    pub fn containerGetByName(self: *DockerClient, name: []const u8) !?[]const u8 {
        // Fetch all containers (running + stopped) and search by name locally.
        // This avoids URL-encoding issues with the Docker filter API.
        var api_path_buf: [128]u8 = undefined;
        const api_path = try std.fmt.bufPrint(
            &api_path_buf,
            "/{s}/containers/json?all=true",
            .{api_version},
        );

        const resp_body = try self.doRequest(.get, api_path, null, null, &.{200});
        defer self.allocator.free(resp_body);

        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            resp_body,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        if (parsed.value != .array) return null;

        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const names_v = item.object.get("Names") orelse continue;
            if (names_v != .array) continue;
            for (names_v.array.items) |name_v| {
                if (name_v != .string) continue;
                const full = name_v.string;
                // Docker names are prefixed with "/": "/containerName"
                const candidate = if (std.mem.startsWith(u8, full, "/"))
                    full[1..]
                else
                    full;
                if (std.mem.eql(u8, candidate, name)) {
                    const id_v = item.object.get("Id") orelse continue;
                    if (id_v != .string) continue;
                    return try self.allocator.dupe(u8, id_v.string);
                }
            }
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // System
    // -----------------------------------------------------------------------

    /// Ping the Docker daemon. Returns true on success.
    pub fn ping(self: *DockerClient) !bool {
        const api_path = "/" ++ api_version ++ "/_ping";
        const url = try self.apiUrl(api_path);
        defer self.allocator.free(url);

        var resp = self.client.fetch(url, .{
            .method = .get,
            .unix_socket_path = self.socket_path,
        }) catch return false;
        defer resp.deinit();

        const sc: u16 = @as(u16, @intCast(@intFromEnum(resp.status())));
        return sc == 200;
    }
};

// ---------------------------------------------------------------------------
// JSON body builders
// ---------------------------------------------------------------------------

fn buildCreateBody(allocator: std.mem.Allocator, req: *const container_mod.ContainerRequest) ![]const u8 {
    // Use a json.Value tree to handle dynamic keys cleanly
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.Value{ .object = std.json.ObjectMap.init(a) };

    try root.object.put("Image", .{ .string = req.image });

    if (req.cmd.len > 0) {
        var cmd_arr = std.json.Value{ .array = std.json.Array.init(a) };
        for (req.cmd) |c| try cmd_arr.array.append(.{ .string = c });
        try root.object.put("Cmd", cmd_arr);
    }

    if (req.entrypoint.len > 0) {
        var ep_arr = std.json.Value{ .array = std.json.Array.init(a) };
        for (req.entrypoint) |e| try ep_arr.array.append(.{ .string = e });
        try root.object.put("Entrypoint", ep_arr);
    }

    if (req.env.len > 0) {
        var env_arr = std.json.Value{ .array = std.json.Array.init(a) };
        for (req.env) |e| try env_arr.array.append(.{ .string = e });
        try root.object.put("Env", env_arr);
    }

    // ExposedPorts: {"80/tcp": {}}
    if (req.exposed_ports.len > 0) {
        var ports_obj = std.json.Value{ .object = std.json.ObjectMap.init(a) };
        for (req.exposed_ports) |p| {
            const normalized = try container_mod.normalizePort(a, p);
            try ports_obj.object.put(normalized, .{ .object = std.json.ObjectMap.init(a) });
        }
        try root.object.put("ExposedPorts", ports_obj);
    }

    // Labels
    if (req.labels.len > 0) {
        var lbl_obj = std.json.Value{ .object = std.json.ObjectMap.init(a) };
        for (req.labels) |kv| try lbl_obj.object.put(kv.key, .{ .string = kv.value });
        try root.object.put("Labels", lbl_obj);
    }

    // HostConfig
    {
        var hc = std.json.Value{ .object = std.json.ObjectMap.init(a) };

        // PortBindings: {"80/tcp": [{"HostIp":"","HostPort":""}]}
        if (req.exposed_ports.len > 0) {
            var pb_obj = std.json.Value{ .object = std.json.ObjectMap.init(a) };
            for (req.exposed_ports) |p| {
                const normalized = try container_mod.normalizePort(a, p);
                var binding_arr = std.json.Value{ .array = std.json.Array.init(a) };
                var binding = std.json.Value{ .object = std.json.ObjectMap.init(a) };
                try binding.object.put("HostIp", .{ .string = "" });
                try binding.object.put("HostPort", .{ .string = "" });
                try binding_arr.array.append(binding);
                try pb_obj.object.put(normalized, binding_arr);
            }
            try hc.object.put("PortBindings", pb_obj);
        }

        // Binds from mounts
        if (req.mounts.len > 0) {
            var binds = std.json.Value{ .array = std.json.Array.init(a) };
            for (req.mounts) |m| {
                if (m.mount_type == .bind) {
                    const bind_str = try std.fmt.allocPrint(
                        a,
                        "{s}:{s}{s}",
                        .{ m.source, m.target, if (m.read_only) ":ro" else "" },
                    );
                    try binds.array.append(.{ .string = bind_str });
                }
            }
            if (binds.array.items.len > 0) {
                try hc.object.put("Binds", binds);
            }
        }

        try root.object.put("HostConfig", hc);
    }

    // NetworkingConfig — attach first network during create
    if (req.networks.len > 0) {
        var nc = std.json.Value{ .object = std.json.ObjectMap.init(a) };
        var endpoints = std.json.Value{ .object = std.json.ObjectMap.init(a) };

        const first_net = req.networks[0];
        var ep = std.json.Value{ .object = std.json.ObjectMap.init(a) };

        // Find aliases for this network
        for (req.network_aliases) |na| {
            if (std.mem.eql(u8, na.network, first_net)) {
                var alias_arr = std.json.Value{ .array = std.json.Array.init(a) };
                for (na.aliases) |alias| try alias_arr.array.append(.{ .string = alias });
                try ep.object.put("Aliases", alias_arr);
            }
        }

        try endpoints.object.put(first_net, ep);
        try nc.object.put("EndpointsConfig", endpoints);
        try root.object.put("NetworkingConfig", nc);
    }

    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root, .{})});
}

fn buildExecCreateBody(allocator: std.mem.Allocator, cmd: []const []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.Value{ .object = std.json.ObjectMap.init(a) };
    try root.object.put("AttachStdout", .{ .bool = true });
    try root.object.put("AttachStderr", .{ .bool = true });
    try root.object.put("AttachStdin", .{ .bool = false });
    try root.object.put("Tty", .{ .bool = false });

    var cmd_arr = std.json.Value{ .array = std.json.Array.init(a) };
    for (cmd) |c| try cmd_arr.array.append(.{ .string = c });
    try root.object.put("Cmd", cmd_arr);

    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root, .{})});
}

fn buildNetworkCreateBody(
    allocator: std.mem.Allocator,
    name: []const u8,
    driver: []const u8,
    labels: []const container_mod.KV,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.Value{ .object = std.json.ObjectMap.init(a) };
    try root.object.put("Name", .{ .string = name });
    try root.object.put("Driver", .{ .string = driver });
    try root.object.put("CheckDuplicate", .{ .bool = true });

    if (labels.len > 0) {
        var lbl_obj = std.json.Value{ .object = std.json.ObjectMap.init(a) };
        for (labels) |kv| try lbl_obj.object.put(kv.key, .{ .string = kv.value });
        try root.object.put("Labels", lbl_obj);
    }

    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root, .{})});
}

fn buildNetworkConnectBody(
    allocator: std.mem.Allocator,
    container_id: []const u8,
    aliases: []const []const u8,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = std.json.Value{ .object = std.json.ObjectMap.init(a) };
    try root.object.put("Container", .{ .string = container_id });

    var ec = std.json.Value{ .object = std.json.ObjectMap.init(a) };
    if (aliases.len > 0) {
        var alias_arr = std.json.Value{ .array = std.json.Array.init(a) };
        for (aliases) |alias| try alias_arr.array.append(.{ .string = alias });
        try ec.object.put("Aliases", alias_arr);
    }
    try root.object.put("EndpointConfig", ec);

    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(root, .{})});
}

// ---------------------------------------------------------------------------
// Simple percent encoder for query param values
// ---------------------------------------------------------------------------

fn uriEncode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (input) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(allocator, c);
        } else {
            var hex_buf: [3]u8 = undefined;
            const hex = try std.fmt.bufPrint(&hex_buf, "%{X:0>2}", .{c});
            try out.appendSlice(allocator, hex);
        }
    }
    return out.toOwnedSlice(allocator);
}
