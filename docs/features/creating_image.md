# Image management

Testcontainers for Zig handles image pulling automatically. When you create a container, the library checks whether the image exists locally and pulls it if needed.

## Automatic pulling

By default, Testcontainers pulls the image only if it is not already present on the Docker host:

```zig
const ctr = try tc.run(allocator, "nginx:1.26-alpine", .{
    .exposed_ports = &.{"80/tcp"},
    .wait_strategy = tc.wait.forHttp("/"),
});
```

## Force pulling

Set `always_pull_image` to `true` to always pull the image, even if it exists locally. This is useful to ensure you're testing against the latest version of a tag:

```zig
const ctr = try tc.run(allocator, "nginx:1.26-alpine", .{
    .exposed_ports = &.{"80/tcp"},
    .always_pull_image = true,
    .wait_strategy = tc.wait.forHttp("/"),
});
```

## Image platform

You can specify the image platform for multi-architecture images:

```zig
const ctr = try tc.run(allocator, "nginx:latest", .{
    .exposed_ports = &.{"80/tcp"},
    .image_platform = "linux/amd64",
    .wait_strategy = tc.wait.forHttp("/"),
});
```

## Low-level image operations

For direct image management, use the `DockerClient` API:

```zig
var provider = tc.DockerProvider.init(allocator);
defer provider.deinit();

// Check if an image exists locally
const exists = try provider.client.imageExists("nginx:latest");

// Pull an image explicitly
try provider.client.imagePull("nginx:latest");
```
