# Garbage Collector / Container Cleanup

Testcontainers for Zig relies on Zig's `defer` mechanism for deterministic container cleanup. Every container must be terminated and freed when it is no longer needed.

## Basic cleanup with `defer`

The recommended pattern is to use `defer` immediately after creating a container:

```zig
test "with cleanup" {
    const allocator = std.testing.allocator;

    const ctr = try tc.run(allocator, "nginx:latest", .{
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forHttp("/"),
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
        tc.deinitProvider();
    }

    // test logic...
}
```

`defer` ensures that `terminate()` and `deinit()` are called when the scope exits, regardless of whether the test passes or fails.

## Module containers

Module containers follow the same pattern:

```zig
test "postgres cleanup" {
    const allocator = std.testing.allocator;

    var provider = tc.DockerProvider.init(allocator);
    defer provider.deinit();

    const pg = try tc.modules.postgres.runDefault(&provider);
    defer pg.terminate() catch {};
    defer pg.deinit();

    // test logic...
}
```

!!! warning

    Always call `terminate()` before `deinit()`. `terminate()` stops and removes the container from Docker. `deinit()` frees the Zig memory. If you only call `deinit()`, the container will keep running in Docker.

## `terminate()` vs `deinit()`

| Method        | What it does                                              |
|---------------|-----------------------------------------------------------|
| `terminate()` | Stops and removes the Docker container (and anonymous volumes). |
| `deinit()`    | Frees the Zig-side memory. Does NOT stop the container.   |

Always call both. Use `defer` to ensure they run:

```zig
defer ctr.terminate() catch {};
defer ctr.deinit();
```

Note: `defer` statements execute in reverse order, so `deinit()` will be called first, then `terminate()`. To ensure `terminate()` runs first, use a single `defer` block:

```zig
defer {
    ctr.terminate() catch {};
    ctr.deinit();
}
```

## Network cleanup

Networks also need cleanup:

```zig
const net = try tc.network.newNetwork(allocator, &provider.client, .{
    .name = "test-network",
});
defer {
    net.remove() catch {};
    net.deinit();
}
```

## Error path cleanup with `errdefer`

When creating resources that may fail during setup, use `errdefer` to clean up partially-created state:

```zig
const ctr = try provider.createContainer(&req);
errdefer {
    ctr.terminate() catch {};
    ctr.deinit();
}
try ctr.start(); // if this fails, errdefer runs cleanup
```
