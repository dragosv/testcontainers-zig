# Custom configuration

You can override some default properties if your environment requires it.

## Docker host detection

Testcontainers for Zig will attempt to detect the Docker environment and configure everything to work automatically.

However, sometimes customization is required. Testcontainers for Zig will respect the following order:

1. **`DOCKER_HOST` environment variable** — If set, this takes priority. The value must use the `unix://` scheme (e.g., `unix:///var/run/docker.sock`). For `unix://` URIs, the path after the scheme is extracted and used as the socket path.
2. **`/var/run/docker.sock`** — Standard Docker socket on macOS and Linux (default fallback).

## Environment variables

| Variable                          | Description                                                       | Example                              |
|-----------------------------------|-------------------------------------------------------------------|--------------------------------------|
| `DOCKER_HOST`                     | Override the Docker daemon socket path.                           | `unix:///var/run/docker.sock`        |
| `TESTCONTAINERS_HOST_OVERRIDE`    | Override the host used to reach containers (e.g. in Docker Desktop). | `host.docker.internal`            |

Set it before running tests:

```bash
export DOCKER_HOST=unix:///var/run/docker.sock
zig build test --summary all
```

Or set it in your CI configuration:

```yaml
env:
  DOCKER_HOST: unix:///var/run/docker.sock
```

## Docker socket path detection

Testcontainers for Zig will attempt to detect the Docker socket path and configure everything to work automatically.

The following locations are checked in order:

| Priority | Location                             | Notes                                       |
|:--------:|--------------------------------------|---------------------------------------------|
| 1        | `DOCKER_HOST` env var                | Parsed from `unix://` prefix                |
| 2        | `/var/run/docker.sock`               | Default path on macOS and Linux              |

## Programmatic configuration

You can initialize the Docker provider with a custom socket path:

```zig
const tc = @import("testcontainers");

// Use default auto-detection (checks DOCKER_HOST, then /var/run/docker.sock)
var provider = tc.DockerProvider.init(allocator);
defer provider.deinit();

// Or specify a custom socket path
var provider2 = tc.DockerProvider.init_with_socket(allocator, "/custom/docker.sock");
defer provider2.deinit();
```

## Logging

Testcontainers for Zig uses Zig's built-in `std.log` for diagnostic output. You can configure the log scope and level at compile time:

```zig
pub const std_options: std.Options = .{
    .log_level = .debug,
};
```

## Platform requirements

| Requirement     | Minimum version      |
|-----------------|----------------------|
| Zig             | 0.15.2               |
| macOS           | 13.0 (Ventura)       |
| Linux           | Ubuntu 22.04+        |
| Docker          | 20.10+               |
