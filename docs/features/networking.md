# Networking

Testcontainers for Zig provides support for Docker networking features including port mapping, custom networks, and inter-container communication.

## Port mapping

When you specify `exposed_ports` in the `ContainerRequest`, Docker maps each container port to a random available host port. Use `mappedPort()` to discover the actual host port:

```zig
const ctr = try tc.run(allocator, "nginx:latest", .{
    .exposed_ports = &.{"80/tcp"},
    .wait_strategy = tc.wait.forHttp("/"),
});
defer {
    ctr.terminate() catch {};
    ctr.deinit();
    tc.deinitProvider();
}

const port = try ctr.mappedPort("80/tcp", allocator);
const host = try ctr.daemonHost(allocator);
defer allocator.free(host);

std.debug.print("Service available at {s}:{d}\n", .{ host, port });
```

## Docker host

The `daemonHost()` method returns the hostname to use when connecting to the container. It checks:

1. `TESTCONTAINERS_HOST_OVERRIDE` environment variable
2. `DOCKER_HOST` environment variable (extracts host from `tcp://` URI)
3. Falls back to `"localhost"`

```zig
const host = try ctr.daemonHost(allocator);
defer allocator.free(host);
```

## Custom networks

Create custom Docker networks for inter-container communication:

```zig
const tc = @import("testcontainers");

var provider = tc.DockerProvider.init(allocator);
defer provider.deinit();

const net = try tc.network.newNetwork(allocator, &provider.client, .{
    .name = "test-network",
    .driver = "bridge",
});
defer {
    net.remove() catch {};
    net.deinit();
}
```

### NetworkRequest fields

| Field        | Type               | Default     | Description                                   |
|--------------|--------------------|-------------|-----------------------------------------------|
| `name`       | `[]const u8`       | (required)  | Network name.                                 |
| `driver`     | `[]const u8`       | `"bridge"`  | Network driver.                               |
| `labels`     | `[]const KV`       | `&.{}`      | Arbitrary labels.                             |
| `internal`   | `bool`             | `false`     | Internal network (no external connectivity).  |
| `attachable` | `bool`             | `true`      | Allow manual container attachment.            |

## Attaching containers to networks

Attach containers to a network using the `networks` field in `ContainerRequest`:

```zig
const ctr = try tc.run(allocator, "nginx:latest", .{
    .exposed_ports = &.{"80/tcp"},
    .networks = &.{"test-network"},
    .network_aliases = &.{.{
        .network = "test-network",
        .aliases = &.{ "web", "frontend" },
    }},
    .wait_strategy = tc.wait.forHttp("/"),
});
```

## Inspecting container networking

```zig
// Get container IP on primary network
const ip = try ctr.containerIP(allocator);
defer allocator.free(ip);

// Get all networks the container is attached to
const nets = try ctr.networks(allocator);
defer {
    for (nets) |n| allocator.free(n);
    allocator.free(nets);
}

// Get aliases for a specific network
const aliases = try ctr.networkAliases("test-network", allocator);
defer {
    for (aliases) |a| allocator.free(a);
    allocator.free(aliases);
}

// Get IP on a specific network
const net_ip = try ctr.networkIP("test-network", allocator);
defer allocator.free(net_ip);
```
