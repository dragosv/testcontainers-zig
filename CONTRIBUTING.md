# Contributing to Testcontainers Zig

First off, thank you for considering contributing to Testcontainers Zig! It's people like you that make Testcontainers such a great tool.

## Code of Conduct

This project and everyone participating in it is governed by our Code of Conduct. By participating, you are expected to uphold this code.

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check the issue list as you might find out that you don't need to create one. When you are creating a bug report, please include as many details as possible:

* **Use a clear and descriptive title**
* **Describe the exact steps which reproduce the problem**
* **Provide specific examples to demonstrate the steps**
* **Describe the behavior you observed after following the steps**
* **Explain which behavior you expected to see instead and why**

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, please include:

* **Use a clear and descriptive title**
* **Provide a step-by-step description of the suggested enhancement**
* **Provide specific examples to demonstrate the steps**
* **Describe the current behavior** and **the suggested behavior**

### Pull Requests

* Follow the Zig style guidelines described below
* Include appropriate test cases
* Update documentation as needed
* End all files with a newline

## Development Setup

1. **Fork the repository**
   ```bash
   git clone https://github.com/yourusername/testcontainers-zig.git
   ```

2. **Create a branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Install Zig 0.15.2**
   See https://ziglang.org/download/ for your platform.

4. **Build the project**
   ```bash
   zig build
   ```

5. **Run unit tests**
   ```bash
   zig build test --summary all
   ```

6. **Run integration tests** (requires Docker)
   ```bash
   zig build integration-test --summary all
   ```

## Style Guidelines

### Zig Code Style

- Use 4 spaces for indentation (no tabs)
- Use `snake_case` for variable, field, and function names
- Use `PascalCase` for type names (structs, enums, unions)
- Use `SCREAMING_SNAKE_CASE` for compile-time constants
- Add `///` doc comments for all public declarations
- Keep lines under 120 characters when possible
- Use `errdefer` to clean up resources in error paths
- Prefer `guard`-style early returns with `if (cond) return error.X`
- Never use `try!` equivalents — propagate errors explicitly

### Example:

```zig
/// A running Docker container.
/// Caller must call `deinit()` when done.
pub const DockerContainer = struct {
    id: []const u8,
    allocator: std.mem.Allocator,

    /// Returns the host port mapped to `port_spec` (e.g. `"5432/tcp"`).
    /// Caller owns the result; free with `allocator.free(result)`.
    pub fn mappedPort(self: *DockerContainer, port_spec: []const u8, alloc: std.mem.Allocator) !u16 {
        // ...
    }
};
```

## Adding New Modules

To add a new container module:

1. Create `src/modules/<name>.zig` following the existing pattern (e.g. `src/modules/postgres.zig`)
2. Export the module inside the `modules` namespace in `src/root.zig`
3. Provide sensible defaults (`default_image`, `Options` struct with default values)
4. Expose connection helpers (`connectionString`, `httpURL`, `brokers`, etc.)
5. Add unit tests in `src/modules/<name>.zig` using `test { ... }`
6. Add an integration test in `src/integration_test.zig`
7. Update documentation

### Module Template

```zig
const std = @import("std");
const tc  = @import("../root.zig");

/// Default image used when callers pass `default_image`.
pub const default_image = "myservice:latest";

/// Configuration options for MyServiceContainer.
pub const Options = struct {
    username: []const u8 = "user",
    password: []const u8 = "pass",
    port:     []const u8 = "5000/tcp",
};

/// A running MyService container.
pub const MyServiceContainer = struct {
    inner:    *tc.DockerContainer,
    opts:     Options,

    /// Start a MyService container.
    pub fn run(provider: *tc.DockerProvider, image: []const u8, opts: Options) !*MyServiceContainer {
        const ctr = try provider.runContainer(provider.alloc, .{
            .image         = image,
            .exposed_ports = &.{opts.port},
            .env           = &.{"MYSERVICE_USER=user"},
            .wait_strategy = tc.wait.forPort(opts.port),
        });
        const self = try provider.alloc.create(MyServiceContainer);
        self.* = .{ .inner = ctr, .opts = opts };
        return self;
    }

    /// Convenience: start with default_image and default options.
    pub fn runDefault(provider: *tc.DockerProvider) !*MyServiceContainer {
        return run(provider, default_image, .{});
    }

    /// Stop and remove the container.
    pub fn terminate(self: *MyServiceContainer) !void {
        try self.inner.terminate();
    }

    /// Free all memory owned by this container wrapper.
    pub fn deinit(self: *MyServiceContainer) void {
        self.inner.deinit();
        // provider.alloc.destroy(self) if you stored the allocator
    }

    /// Returns the service URL. Caller owns result.
    pub fn connectionString(self: *MyServiceContainer, alloc: std.mem.Allocator) ![]u8 {
        const port = try self.inner.mappedPort(self.opts.port, alloc);
        const host = try self.inner.daemonHost(alloc);
        defer alloc.free(host);
        return std.fmt.allocPrint(alloc, "http://{s}:{d}", .{ host, port });
    }
};
```

## Testing

- Write `test { ... }` blocks for all new public functions
- Run `zig build test --summary all` before submitting a pull request
- Integration tests that require Docker should check reachability and return `error.SkipZigTest` when Docker is unavailable
- Tests must be deterministic and not flaky

### Integration test skeleton

```zig
test "myservice: start and connect" {
    const alloc = std.testing.allocator;
    var provider = tc.DockerProvider.init(alloc) catch return error.SkipZigTest;
    defer provider.deinit();

    const ctr = try tc.modules.myservice.runDefault(&provider);
    defer ctr.terminate() catch {};
    defer ctr.deinit();

    const url = try ctr.connectionString(alloc);
    defer alloc.free(url);
    try std.testing.expect(url.len > 0);
}
```

## Documentation

- Update README.md with new features
- Add code examples for new modules
- Document API changes in `IMPLEMENTATION_GUIDE.md`
- Keep `PROJECT_SUMMARY.md` feature table up-to-date

## Git Commits

- Use clear and descriptive commit messages
- Use the present tense ("Add feature" not "Added feature")
- Use the imperative mood ("Move cursor to..." not "Moves cursor to...")
- Limit the first line to 72 characters or less
- Reference issues and pull requests liberally after the first line

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

## Questions?

Feel free to reach out to the maintainers:
- Open an issue on GitHub
- Join the Testcontainers [Slack workspace](https://slack.testcontainers.org/)

Thank you for contributing!
