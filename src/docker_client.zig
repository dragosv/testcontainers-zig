/// DockerClient — thin wrapper around the DockerHttp Unix-socket HTTP client
/// that speaks the Docker Engine REST API.
///
/// All responses are allocated with the caller-supplied allocator; the caller
/// is responsible for freeing them unless documented otherwise.
const std = @import("std");
const http_mod = @import("http.zig");
const DockerHttp = http_mod.DockerHttp;
const types = @import("types.zig");
const container_mod = @import("container.zig");

/// Default Docker socket path.
pub const docker_socket = "/var/run/docker.sock";

/// Docker Engine API version used for all requests.
pub const api_version = "v1.46";

/// Pseudo-host used in the HTTP request line (Docker ignores it).
pub const api_host = "http://localhost";

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

    pub fn init(allocator: std.mem.Allocator, socket_path: []const u8) DockerClient {
        return .{
            .allocator = allocator,
            .socket_path = socket_path,
        };
    }

    pub fn deinit(self: *DockerClient) void {
        _ = self; // nothing to release
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    /// Perform a request and check that the status code is acceptable.
    /// Returns the raw body bytes (caller owns the memory).
    fn doRequest(
        self: *DockerClient,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
        content_type: ?[]const u8,
        expected_codes: []const u16,
    ) ![]const u8 {
        var dh = DockerHttp.init(self.allocator, self.socket_path);
        var resp = try dh.request(method, path, content_type, body);
        defer resp.deinit();

        const status_code = resp.status;

        var acceptable = false;
        for (expected_codes) |c| {
            if (c == status_code) {
                acceptable = true;
                break;
            }
        }

        if (!acceptable) {
            if (status_code == 404) return DockerClientError.NotFound;
            if (status_code == 409) return DockerClientError.Conflict;
            if (status_code >= 500) return DockerClientError.ServerError;
            return DockerClientError.ApiError;
        }

        return self.allocator.dupe(u8, resp.body);
    }

    /// Like doRequest but returns a live StreamingResponse for streaming.
    /// The caller must call resp.close() when done.
    fn doStream(
        self: *DockerClient,
        method: []const u8,
        path: []const u8,
        body: ?[]const u8,
    ) !http_mod.StreamingResponse {
        var dh = DockerHttp.init(self.allocator, self.socket_path);
        return dh.requestStream(method, path, body);
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

        // The response is a stream of JSON progress objects; we consume it
        // fully to wait for the pull to finish.
        var resp = try self.doStream("POST", api_path, null);
        defer resp.close();

        if (resp.status != 200) return DockerClientError.ApiError;

        // Drain the stream (each chunk is a JSON object on one line)
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = resp.read(&buf) catch break;
            if (n == 0) break;
        }
    }

    /// Check if an image exists locally. Returns true if found.
    pub fn imageExists(self: *DockerClient, image_ref: []const u8) !bool {
        const encoded = try uriEncode(self.allocator, image_ref);
        defer self.allocator.free(encoded);

        const api_path = try std.fmt.allocPrint(self.allocator, "/{s}/images/{s}/json", .{ api_version, encoded });
        defer self.allocator.free(api_path);

        _ = self.doRequest("GET", api_path, null, null, &.{200}) catch |err| {
            if (err == DockerClientError.NotFound) return false;
            return err;
        };
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

        const resp_body = try self.doRequest("POST", api_path, body_json, "application/json", &.{201});
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
        const body = try self.doRequest("POST", api_path, null, null, &.{ 204, 304 });
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

        const body = self.doRequest("POST", api_path, null, null, &.{ 204, 304 }) catch |err| {
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

        const body = self.doRequest("DELETE", api_path, null, null, &.{204}) catch |err| {
            if (err == DockerClientError.NotFound) return;
            return err;
        };
        self.allocator.free(body);
    }

    /// Inspect a container. Caller owns the returned JSON bytes.
    pub fn containerInspectRaw(self: *DockerClient, id: []const u8) ![]const u8 {
        const api_path = try std.fmt.allocPrint(self.allocator, "/{s}/containers/{s}/json", .{ api_version, id });
        defer self.allocator.free(api_path);
        return self.doRequest("GET", api_path, null, null, &.{200});
    }

    /// Returns the parsed inspect structure. The caller must call `.deinit()`
    /// on the returned `Parsed(T)` to free the JSON arena.
    pub fn containerInspect(
        self: *DockerClient,
        id: []const u8,
    ) !std.json.Parsed(types.ContainerInspect) {
        const raw = try self.containerInspectRaw(id);
        defer self.allocator.free(raw);
        return std.json.parseFromSlice(
            types.ContainerInspect,
            self.allocator,
            raw,
            .{ .ignore_unknown_fields = true },
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

        var resp = try self.doStream("GET", api_path, null);
        defer resp.close();

        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);

        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = resp.read(&tmp) catch break;
            if (n == 0) break;
            try buf.appendSlice(self.allocator, tmp[0..n]);
        }

        return buf.toOwnedSlice(self.allocator);
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

        const create_resp = try self.doRequest("POST", create_api_path, create_body, "application/json", &.{201});
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

        var start_resp = try self.doStream("POST", start_api_path, start_body);
        defer start_resp.close();

        var output_buf: std.ArrayList(u8) = .empty;
        errdefer output_buf.deinit(self.allocator);

        var tmp: [4096]u8 = undefined;
        while (true) {
            const n = start_resp.read(&tmp) catch break;
            if (n == 0) break;
            try output_buf.appendSlice(self.allocator, tmp[0..n]);
        }

        const raw_output = try output_buf.toOwnedSlice(self.allocator);
        defer self.allocator.free(raw_output);
        const output = try decodeLogs(self.allocator, raw_output);

        // 3. Inspect exec to get exit code
        const inspect_api_path = try std.fmt.allocPrint(self.allocator, "/{s}/exec/{s}/json", .{ api_version, exec_id });
        defer self.allocator.free(inspect_api_path);

        const inspect_body = try self.doRequest("GET", inspect_api_path, null, null, &.{200});
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

        const resp_body = try self.doRequest("POST", api_path, body, "application/json", &.{201});
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

        const body = self.doRequest("DELETE", api_path, null, null, &.{204}) catch |err| {
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

        const resp = try self.doRequest("POST", api_path, body, "application/json", &.{200});
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
        const body = try self.doRequest("PUT", api_path, tar_data, "application/x-tar", &.{200});
        self.allocator.free(body);
    }

    // -----------------------------------------------------------------------
    // System
    // -----------------------------------------------------------------------

    /// Ping the Docker daemon. Returns true on success.
    pub fn ping(self: *DockerClient) !bool {
        var dh = DockerHttp.init(self.allocator, self.socket_path);
        var resp = dh.request("GET", "/" ++ api_version ++ "/_ping", null, null) catch return false;
        defer resp.deinit();
        return resp.status == 200;
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
