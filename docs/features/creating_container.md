# Creating a container

The core API for creating containers in Testcontainers for Zig is the `ContainerRequest` struct, configured using Zig's struct-literal syntax with named fields and sensible defaults.

## Using `ContainerRequest`

```zig
const tc = @import("testcontainers");

const ctr = try tc.run(allocator, "nginx:1.26-alpine", .{
    .exposed_ports = &.{"80/tcp"},
    .wait_strategy = tc.wait.forHttp("/"),
});
defer {
    ctr.terminate() catch {};
    ctr.deinit();
    tc.deinitProvider();
}
```

## ContainerRequest fields

| Field               | Type                         | Default     | Description                                           |
|---------------------|------------------------------|-------------|-------------------------------------------------------|
| `image`             | `[]const u8`                 | `""`        | Docker image reference (e.g. `"nginx:latest"`).       |
| `cmd`               | `[]const []const u8`         | `&.{}`      | Command override (replaces image default CMD).         |
| `entrypoint`        | `[]const []const u8`         | `&.{}`      | Entrypoint override.                                   |
| `env`               | `[]const []const u8`         | `&.{}`      | Environment variables as `KEY=VALUE` strings.          |
| `exposed_ports`     | `[]const []const u8`         | `&.{}`      | Ports to expose (e.g. `"5432/tcp"`, `"80"`).           |
| `labels`            | `[]const KV`                 | `&.{}`      | Arbitrary labels for the container.                    |
| `name`              | `?[]const u8`                | `null`      | Optional container name.                               |
| `wait_strategy`     | `wait.Strategy`              | `.none`     | Wait strategy executed after the container starts.     |
| `networks`          | `[]const []const u8`         | `&.{}`      | Networks to attach the container to.                   |
| `network_aliases`   | `[]const NetworkAlias`       | `&.{}`      | Network aliases per network.                           |
| `mounts`            | `[]const Mount`              | `&.{}`      | Bind-mounts and named volumes.                         |
| `files`             | `[]const ContainerFile`      | `&.{}`      | Files to copy into the container.                      |
| `always_pull_image` | `bool`                       | `false`     | Always pull the image even if present locally.         |
| `image_platform`    | `[]const u8`                 | `""`        | Image platform (e.g. `"linux/amd64"`).                 |
| `startup_timeout_ns`| `u64`                        | `0`         | Startup timeout in nanoseconds (0 = use default 60s). |

## Using `DockerProvider` directly

For more control, use a `DockerProvider` to create and manage containers:

```zig
const tc = @import("testcontainers");

var provider = tc.DockerProvider.init(allocator);
defer provider.deinit();

const req = tc.ContainerRequest{
    .image = "nginx:1.26-alpine",
    .exposed_ports = &.{"80/tcp"},
    .wait_strategy = tc.wait.forHttp("/"),
};

const ctr = try provider.runContainer(&req);
defer {
    ctr.terminate() catch {};
    ctr.deinit();
}
```

## Setting environment variables

```zig
const ctr = try tc.run(allocator, "postgres:16", .{
    .env = &.{
        "POSTGRES_USER=admin",
        "POSTGRES_PASSWORD=secret",
        "POSTGRES_DB=testdb",
    },
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = tc.wait.forLog("database system is ready to accept connections"),
});
```

## Setting the command

```zig
const ctr = try tc.run(allocator, "alpine:latest", .{
    .cmd = &.{ "sh", "-c", "echo hello && sleep 30" },
    .wait_strategy = tc.wait.forLog("hello"),
});
```

## Mounting volumes

```zig
const ctr = try tc.run(allocator, "nginx:latest", .{
    .exposed_ports = &.{"80/tcp"},
    .mounts = &.{.{
        .mount_type = .bind,
        .source = "/host/path/html",
        .target = "/usr/share/nginx/html",
        .read_only = true,
    }},
    .wait_strategy = tc.wait.forHttp("/"),
});
```

## Using `GenericContainerRequest`

For advanced lifecycle control (e.g. creating a container without starting it, or reusing an existing container by name):

```zig
const tc = @import("testcontainers");

const ctr = try tc.genericContainer(allocator, .{
    .container_request = .{
        .image = "nginx:latest",
        .exposed_ports = &.{"80/tcp"},
        .name = "my-nginx",
    },
    .started = false, // create but don't start
    .reuse = true,    // reuse existing container with same name
});
```
