# Wait strategies

Wait strategies control when a container is considered "ready" after it starts. Testcontainers for Zig uses a tagged union (`wait.Strategy`) to represent different strategies. You set the strategy on the `wait_strategy` field of `ContainerRequest`.

## Available strategies

| Strategy    | Constructor               | Description                                                             |
|-------------|---------------------------|-------------------------------------------------------------------------|
| Log         | `wait.forLog(message)`    | Wait for a specific substring in container logs.                        |
| HTTP        | `wait.forHttp(path)`      | Wait for an HTTP endpoint to return the expected status code.           |
| Port        | `wait.forPort(port)`      | Wait for a TCP port to be reachable on the container.                   |
| Health Check| `wait.forHealthCheck()`   | Wait for Docker's built-in health check to report "healthy".            |
| Exec        | `wait.forExec(cmd)`       | Wait for a command executed inside the container to return exit code 0. |
| All         | `wait.forAll(strategies)` | Combine multiple strategies — all must succeed (run serially).          |
| None        | `.none`                   | No waiting (default).                                                   |

## Log strategy

Wait for a specific log message to appear in the container output:

```zig
const ctr = try tc.run(allocator, "postgres:16", .{
    .env = &.{"POSTGRES_PASSWORD=password"},
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = tc.wait.forLog("database system is ready to accept connections"),
});
```

### LogStrategy options

| Field                | Type        | Default | Description                                         |
|----------------------|-------------|---------|-----------------------------------------------------|
| `log`                | `[]const u8`| —       | The log substring to search for.                    |
| `is_regexp`          | `bool`      | `false` | Treat `log` as a regular expression.                |
| `occurrence`         | `u32`       | `1`     | Number of times the pattern must appear.            |
| `startup_timeout_ns` | `u64`       | `0`     | Timeout in nanoseconds (0 = default 60s).           |
| `poll_interval_ns`   | `u64`       | `0`     | Polling interval in nanoseconds (0 = default 100ms).|

For finer control, set the strategy field directly:

```zig
const ctr = try tc.run(allocator, "postgres:16", .{
    .env = &.{"POSTGRES_PASSWORD=password"},
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = .{ .log = .{
        .log = "database system is ready to accept connections",
        .occurrence = 2,
        .startup_timeout_ns = 30 * std.time.ns_per_s,
    }},
});
```

## HTTP strategy

Wait for an HTTP endpoint to return a specific status code:

```zig
const ctr = try tc.run(allocator, "nginx:latest", .{
    .exposed_ports = &.{"80/tcp"},
    .wait_strategy = tc.wait.forHttp("/"),
});
```

### HttpStrategy options

| Field                | Type        | Default | Description                                      |
|----------------------|-------------|---------|--------------------------------------------------|
| `path`               | `[]const u8`| `"/"`   | URL path to poll.                                |
| `port`               | `[]const u8`| `""`    | Container port spec. Empty = first exposed port. |
| `status_code`        | `u16`       | `200`   | Expected HTTP status code. 0 = any 2xx.          |
| `use_tls`            | `bool`      | `false` | Use HTTPS instead of HTTP.                       |
| `method`             | `[]const u8`| `"GET"` | HTTP method (uppercase).                         |
| `startup_timeout_ns` | `u64`       | `0`     | Timeout in nanoseconds (0 = default 60s).        |
| `poll_interval_ns`   | `u64`       | `0`     | Polling interval in nanoseconds.                 |

## Port strategy

Wait for a TCP port to be reachable:

```zig
const ctr = try tc.run(allocator, "postgres:16", .{
    .env = &.{"POSTGRES_PASSWORD=password"},
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = tc.wait.forPort("5432/tcp"),
});
```

## Health check strategy

Wait for Docker's built-in health check to report "healthy":

```zig
const ctr = try tc.run(allocator, "my-image:latest", .{
    .wait_strategy = tc.wait.forHealthCheck(),
});
```

!!! note

    The image must define a `HEALTHCHECK` instruction in its Dockerfile.

## Exec strategy

Wait for a command to succeed (exit code 0) inside the container:

```zig
const ctr = try tc.run(allocator, "postgres:16", .{
    .env = &.{"POSTGRES_PASSWORD=password"},
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = tc.wait.forExec(&.{ "pg_isready", "-U", "postgres" }),
});
```

### ExecStrategy options

| Field                | Type                   | Default | Description                                   |
|----------------------|------------------------|---------|-----------------------------------------------|
| `cmd`                | `[]const []const u8`   | —       | Command to run inside the container.          |
| `expected_exit_code` | `i64`                  | `0`     | Expected exit code for success.               |
| `startup_timeout_ns` | `u64`                  | `0`     | Timeout in nanoseconds (0 = default 60s).     |
| `poll_interval_ns`   | `u64`                  | `0`     | Polling interval in nanoseconds.              |

## Combining strategies

Use `wait.forAll()` to require multiple strategies to succeed:

```zig
const strategies = [_]tc.wait.Strategy{
    tc.wait.forPort("5432/tcp"),
    tc.wait.forLog("database system is ready to accept connections"),
};

const ctr = try tc.run(allocator, "postgres:16", .{
    .env = &.{"POSTGRES_PASSWORD=password"},
    .exposed_ports = &.{"5432/tcp"},
    .wait_strategy = tc.wait.forAll(&strategies),
});
```

Strategies run serially — each must succeed before the next is attempted.

## Timeouts

All strategies default to a 60-second startup timeout and a 100ms polling interval. Override per-strategy:

```zig
.wait_strategy = .{ .log = .{
    .log = "ready",
    .startup_timeout_ns = 120 * std.time.ns_per_s,
    .poll_interval_ns = 500 * std.time.ns_per_ms,
}},
```

Or set a global timeout on the `ContainerRequest`:

```zig
const ctr = try tc.run(allocator, "slow-image:latest", .{
    .startup_timeout_ns = 120 * std.time.ns_per_s,
    .wait_strategy = tc.wait.forLog("ready"),
});
```
