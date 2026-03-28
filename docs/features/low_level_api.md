# Low-level API

For advanced use cases, you can access the `DockerClient` directly. The client communicates with the Docker daemon over its Unix domain socket using a built-in HTTP/1.1 client.

## Accessing the DockerClient

```zig
const tc = @import("testcontainers");

var provider = tc.DockerProvider.init(allocator);
defer provider.deinit();

// Access the client through the provider
const client = &provider.client;
```

## Image operations

```zig
// Check if an image exists locally
const exists = try client.imageExists("nginx:latest");

// Pull an image
try client.imagePull("nginx:latest");
```

## Container operations

```zig
// Create a container (returns container ID)
const req = tc.ContainerRequest{
    .image = "nginx:latest",
    .exposed_ports = &.{"80/tcp"},
};
const id = try client.containerCreate(&req, null);
defer allocator.free(id);

// Start a container
try client.containerStart(id);

// Stop a container (with timeout in seconds)
try client.containerStop(id, 10);

// Remove a container
try client.containerRemove(id, true, true);

// Inspect a container
var parsed = try client.containerInspect(id);
defer parsed.deinit();

// Execute a command in a container
const result = try client.containerExec(id, &.{ "echo", "hello" });
defer allocator.free(result.output);

// Get container logs
const logs = try client.containerLogs(id);
defer allocator.free(logs);
```

## Network operations

```zig
// Create a network
const net_id = try client.networkCreate("test-net", "bridge");
defer allocator.free(net_id);

// Connect a container to a network
try client.networkConnect("test-net", container_id, &.{"alias1"});

// Remove a network
try client.networkRemove(net_id);
```

!!! warning

    The low-level API gives you direct access to Docker operations without lifecycle management. You are responsible for cleaning up all resources you create.
