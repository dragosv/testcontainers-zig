/// testcontainers-zig
///
/// A Zig port of https://github.com/testcontainers/testcontainers-go.
/// Uses https://github.com/dragosv/dusty (main branch) as the
/// HTTP library for communicating with the Docker Engine over its Unix socket.
///
/// Quick start:
///
///   const std = @import("std");
///   const zio = @import("zio");
///   const tc  = @import("testcontainers");
///
///   pub fn main() !void {
///       var gpa = std.heap.GeneralPurposeAllocator(.{}){};
///       defer _ = gpa.deinit();
///       const allocator = gpa.allocator();
///
///       var rt = try zio.Runtime.init(allocator, .{});
///       defer rt.deinit();
///
///       const ctr = try tc.run(allocator, "nginx:latest", .{
///           .exposed_ports = &.{"80/tcp"},
///           .wait_strategy  = tc.wait.forHttp("/"),
///       });
///       defer ctr.terminate() catch {};
///
///       const port = try ctr.mappedPort("80/tcp", allocator);
///       std.debug.print("nginx at localhost:{d}\n", .{port});
///   }
///
/// IMPORTANT: A `zio.Runtime` must be initialised (and kept alive) before
/// calling any testcontainers function that performs I/O, because dusty's
/// async networking is driven by the zio event loop.
const std = @import("std");

// ---------------------------------------------------------------------------
// Re-exports
// ---------------------------------------------------------------------------

pub const wait = @import("wait.zig");
pub const network = @import("network.zig");
pub const ContainerRequest = @import("container.zig").ContainerRequest;
pub const GenericContainerRequest = @import("container.zig").GenericContainerRequest;
pub const TerminateOptions = @import("container.zig").TerminateOptions;
pub const ContainerFile = @import("container.zig").ContainerFile;
pub const Mount = @import("container.zig").Mount;
pub const KV = @import("container.zig").KV;
pub const NetworkAlias = @import("container.zig").NetworkAlias;
pub const DockerContainer = @import("docker_container.zig").DockerContainer;
pub const DockerClient = @import("docker_client.zig").DockerClient;
pub const docker_socket = @import("docker_client.zig").docker_socket;

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// A DockerProvider holds a shared DockerClient and orchestrates container
/// creation.  Most users will not need to interact with it directly.
pub const DockerProvider = struct {
    allocator: std.mem.Allocator,
    client: DockerClient,

    pub fn init(allocator: std.mem.Allocator) DockerProvider {
        return init_with_socket(allocator, docker_socket);
    }

    pub fn init_with_socket(allocator: std.mem.Allocator, socket_path: []const u8) DockerProvider {
        return .{
            .allocator = allocator,
            .client = DockerClient.init(allocator, socket_path),
        };
    }

    pub fn deinit(self: *DockerProvider) void {
        self.client.deinit();
    }

    /// Create a container (not started). Caller owns the returned pointer.
    pub fn createContainer(
        self: *DockerProvider,
        req: *const ContainerRequest,
    ) !*DockerContainer {
        // Pull image when needed
        const should_pull = req.always_pull_image or
            !(try self.client.imageExists(req.image));

        if (should_pull) {
            try self.client.imagePull(req.image);
        }

        // Create the container
        const id = try self.client.containerCreate(req, req.name);

        // Attach additional networks (beyond the first which is set in create)
        if (req.networks.len > 1) {
            for (req.networks[1..]) |net_name| {
                const aliases = blk: {
                    for (req.network_aliases) |na| {
                        if (std.mem.eql(u8, na.network, net_name)) break :blk na.aliases;
                    }
                    break :blk &[_][]const u8{};
                };
                try self.client.networkConnect(net_name, id, aliases);
            }
        }

        // Copy files
        if (req.files.len > 0) {
            // We need to start the container briefly to copy files, then let
            // the caller start it properly.  Alternatively, we can use the
            // create+cp workflow.  Here we do a pre-start cp loop.
            for (req.files) |f| {
                const file_content = if (f.content) |c|
                    c
                else if (f.host_path) |hp| blk: {
                    const fc = try std.fs.cwd().readFileAlloc(
                        self.allocator,
                        hp,
                        16 * 1024 * 1024,
                    );
                    break :blk fc;
                } else return error.NoFileContent;

                // For now, we use containerExec to run a chmod after start.
                _ = file_content;
                _ = f.container_path;
                // TODO: call copyToContainer after start in lifecycle hooks
            }
        }

        const ctr = try self.allocator.create(DockerContainer);
        ctr.* = .{
            .id = id,
            .image = try self.allocator.dupe(u8, req.image),
            .is_running = false,
            .allocator = self.allocator,
            .client = &self.client,
            .wait_strategy = req.wait_strategy,
        };
        return ctr;
    }

    /// Create and optionally start a container.
    /// NOTE: If the wait strategy fails, the container has already been created
    /// in Docker but the error propagates to the caller. Use `createContainer`
    /// + `start()` separately if you need the container reference on failure.
    pub fn runContainer(
        self: *DockerProvider,
        req: *const ContainerRequest,
    ) !*DockerContainer {
        const ctr = try self.createContainer(req);
        errdefer { ctr.terminate() catch {}; ctr.deinit(); }
        try ctr.start();
        return ctr;
    }

    /// Create and start a container with reuse / lifecycle control.
    ///
    /// When `greq.reuse` is true and a container with the same name already
    /// exists, the existing container is returned (already started).
    /// When `greq.reuse` is false and a container with that name exists, the
    /// Docker daemon returns a 409 Conflict error.
    ///
    /// When `greq.started` is false, the container is created but not started.
    pub fn runGenericContainer(
        self: *DockerProvider,
        greq: *const GenericContainerRequest,
    ) !*DockerContainer {
        const req = &greq.container_request;

        // Reuse: find existing container by name
        if (greq.reuse) {
            const name = req.name orelse return error.ContainerNameRequired;
            std.debug.print("[reuse] searching for container '{s}'\n", .{name});
            if (try self.client.containerGetByName(name)) |existing_id| {
                defer self.allocator.free(existing_id);
                std.debug.print("[reuse] found container ID={s}\n", .{existing_id});
                const ctr = try self.allocator.create(DockerContainer);
                ctr.* = .{
                    .id = try self.allocator.dupe(u8, existing_id),
                    .image = try self.allocator.dupe(u8, req.image),
                    .is_running = true,
                    .allocator = self.allocator,
                    .client = &self.client,
                    .wait_strategy = req.wait_strategy,
                };
                // start() accepts 304 (already running) and re-runs wait strategy
                try ctr.start();
                return ctr;
            }
        }

        const ctr = try self.createContainer(req);
        if (!greq.started) return ctr;
        errdefer { ctr.terminate() catch {}; ctr.deinit(); }
        try ctr.start();
        return ctr;
    }
};

// ---------------------------------------------------------------------------
// Top-level convenience functions
// ---------------------------------------------------------------------------

/// Global provider used by the module-level `run` and `genericContainer`
/// helpers.  Created lazily.  Most test frameworks only use one provider.
var global_provider: ?DockerProvider = null;
var global_provider_allocator: std.mem.Allocator = undefined;

/// Initialise (or reset) the module-level provider.
/// Must be called before `run` / `genericContainer` when the global provider
/// is used.
pub fn initProvider(allocator: std.mem.Allocator) void {
    if (global_provider) |*p| p.deinit();
    global_provider = DockerProvider.init(allocator);
    global_provider_allocator = allocator;
}

/// Deinit the module-level provider.
pub fn deinitProvider() void {
    if (global_provider) |*p| {
        p.deinit();
        global_provider = null;
    }
}

/// Create and start a container using the module-level provider.
/// This mirrors `testcontainers-go`'s `Run(ctx, image, opts...)`.
///
/// The caller must call `ctr.terminate()` (and optionally `ctr.deinit()`)
/// when done.
pub fn run(
    allocator: std.mem.Allocator,
    image: []const u8,
    req: ContainerRequest,
) !*DockerContainer {
    if (global_provider == null) {
        global_provider = DockerProvider.init(allocator);
        global_provider_allocator = allocator;
    }

    var effective_req = req;
    effective_req.image = image;

    return global_provider.?.runContainer(&effective_req);
}

/// Lower-level entry point, analogous to `testcontainers-go`'s
/// `GenericContainer`.
pub fn genericContainer(
    allocator: std.mem.Allocator,
    req: GenericContainerRequest,
) !*DockerContainer {
    if (global_provider == null) {
        global_provider = DockerProvider.init(allocator);
        global_provider_allocator = allocator;
    }

    if (req.started) {
        return global_provider.?.runContainer(&req.container_request);
    } else {
        return global_provider.?.createContainer(&req.container_request);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "normalizePort adds /tcp suffix" {
    const allocator = std.testing.allocator;
    const container_mod2 = @import("container.zig");
    const result = try container_mod2.normalizePort(allocator, "8080");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("8080/tcp", result);
}

test "normalizePort keeps existing suffix" {
    const allocator = std.testing.allocator;
    const container_mod2 = @import("container.zig");
    const result = try container_mod2.normalizePort(allocator, "8080/udp");
    // No allocation needed — same slice returned
    try std.testing.expectEqualStrings("8080/udp", result);
}
