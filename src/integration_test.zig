/// Integration tests for testcontainers-zig.
///
/// These tests mirror the Go testcontainers test suite.
/// They require a running Docker daemon on the default socket.
///
/// Run with:
///   zig build integration-test
///
/// Tests are automatically skipped when Docker is not reachable.
const std = @import("std");
const tc = @import("testcontainers");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Skip the test if Docker is not responding on the default socket.
fn skipIfNoDocker(alloc: std.mem.Allocator) !void {
    var client = tc.DockerClient.init(alloc, tc.docker_socket);
    defer client.deinit();
    const ok = client.ping() catch false;
    if (!ok) return error.SkipZigTest;
}

/// Generate a name unique enough for isolated test runs.
fn uniqueName(alloc: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const ts: u64 = @intCast(@max(0, std.time.milliTimestamp()));
    return std.fmt.allocPrint(alloc, "tc-zig-{s}-{d}", .{ prefix, ts });
}

// ---------------------------------------------------------------------------
// Test: CustomLabelsImage
// Mirrors: TestCustomLabelsImage in container_test.go
// ---------------------------------------------------------------------------

test "CustomLabelsImage" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const labels = [_]tc.KV{
        .{ .key = "org.testcontainers.zig", .value = "integration-test" },
        .{ .key = "test.label", .value = "custom-value" },
    };

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 30" },
        .labels = &labels,
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    var inspected = try ctr.inspect();
    defer inspected.deinit();

    const ctr_labels = inspected.value.Config.Labels orelse
        return error.NoLabels;
    try std.testing.expect(ctr_labels == .object);

    const v1 = ctr_labels.object.get("org.testcontainers.zig") orelse
        return error.LabelNotFound;
    try std.testing.expectEqualStrings("integration-test", v1.string);

    const v2 = ctr_labels.object.get("test.label") orelse
        return error.LabelNotFound;
    try std.testing.expectEqualStrings("custom-value", v2.string);
}

// ---------------------------------------------------------------------------
// Test: GetLogsFromFailedContainer
// Mirrors: Test_GetLogsFromFailedContainer in container_test.go
// ---------------------------------------------------------------------------

test "GetLogsFromFailedContainer" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    // The container logs "I was not expecting this" but the wait strategy
    // looks for "I was expecting this" — so start() will return WaitStrategyTimeout.
    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "echo 'I was not expecting this'; sleep 10" },
        .wait_strategy = .{
            .log = .{
                .log = "I was expecting this",
                .startup_timeout_ns = 5 * std.time.ns_per_s,
            },
        },
    };

    // Use createContainer + start() so we keep the container ref on error.
    const ctr = try provider.createContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const start_err = ctr.start();
    try std.testing.expectError(error.WaitStrategyTimeout, start_err);

    // Container should still be accessible — fetch its logs.
    const logs = try ctr.logs();
    defer alloc.free(logs);
    try std.testing.expect(std.mem.indexOf(u8, logs, "I was not expecting this") != null);
}

// ---------------------------------------------------------------------------
// Test: ContainerInspectState
// ---------------------------------------------------------------------------

test "ContainerInspectState" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 60" },
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    try std.testing.expect(try ctr.isRunning());

    // Verify state by inspecting directly without going through stateStatus helper
    var inspected = try ctr.inspect();
    defer inspected.deinit();
    try std.testing.expectEqualStrings("running", inspected.value.State.Status);
}

// ---------------------------------------------------------------------------
// Test: ContainerExec
// ---------------------------------------------------------------------------

test "ContainerExec" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 60" },
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    // Run a command and check its exit code and output.
    const result = try ctr.exec(&.{ "sh", "-c", "echo hello-from-container" });
    defer alloc.free(result.output);

    try std.testing.expectEqual(@as(i64, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello-from-container") != null);
}

// ---------------------------------------------------------------------------
// Test: ContainerExecNonZeroExit
// ---------------------------------------------------------------------------

test "ContainerExecNonZeroExit" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 60" },
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const result = try ctr.exec(&.{ "sh", "-c", "exit 42" });
    defer alloc.free(result.output);
    try std.testing.expectEqual(@as(i64, 42), result.exit_code);
}

// ---------------------------------------------------------------------------
// Test: ContainerCopyToContainer
// ---------------------------------------------------------------------------

test "ContainerCopyToContainer" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 60" },
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const content = "#!/bin/sh\necho hello-copied-file\n";
    try ctr.copyToContainer(content, "/tmp/hello.sh", 0o755);

    const result = try ctr.exec(&.{ "sh", "/tmp/hello.sh" });
    defer alloc.free(result.output);
    try std.testing.expectEqual(@as(i64, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello-copied-file") != null);
}

// ---------------------------------------------------------------------------
// Test: WaitForLogStrategy
// Mirrors: wait strategy usage in generic_test.go
// ---------------------------------------------------------------------------

test "WaitForLogStrategy" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "echo 'service is ready'; sleep 60" },
        .wait_strategy = tc.wait.forLog("service is ready"),
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    try std.testing.expect(try ctr.isRunning());
}

// ---------------------------------------------------------------------------
// Test: WaitForPortStrategy
// Mirrors: wait.ForListeningPort usage
// ---------------------------------------------------------------------------

test "WaitForPortStrategy" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "nginx:alpine",
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forPort("80/tcp"),
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const port = try ctr.mappedPort("80/tcp", alloc);
    try std.testing.expect(port > 0);
}

// ---------------------------------------------------------------------------
// Test: WaitForHTTPStrategy
// Mirrors: wait.ForHTTP usage in container_test.go / generic_test.go
// ---------------------------------------------------------------------------

test "WaitForHTTPStrategy" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "nginx:alpine",
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forHttp("/"),
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const port = try ctr.mappedPort("80/tcp", alloc);
    try std.testing.expect(port > 0);

    // Verify the endpoint is reachable via TCP.
    const host = try ctr.daemonHost(alloc);
    defer alloc.free(host);
    const stream = try std.net.tcpConnectToHost(alloc, host, port);
    stream.close();
}

// ---------------------------------------------------------------------------
// Test: ContainerMappedPort
// Mirrors: MappedPort usage / TestShouldStartContainersInParallel
// ---------------------------------------------------------------------------

test "ContainerMappedPort" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "nginx:alpine",
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forPort("80/tcp"),
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const port = try ctr.mappedPort("80/tcp", alloc);
    try std.testing.expect(port >= 1024); // ephemeral port range
}

// ---------------------------------------------------------------------------
// Test: ShouldStartMultipleContainers
// Mirrors: TestShouldStartContainersInParallel (run sequentially in Zig)
// ---------------------------------------------------------------------------

test "ShouldStartMultipleContainers" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    var containers: std.ArrayList(*tc.DockerContainer) = .empty;
    defer {
        for (containers.items) |ctr| {
            ctr.terminate() catch {};
            ctr.deinit();
        }
        containers.deinit(alloc);
    }

    for (0..3) |_| {
        const req = tc.ContainerRequest{
            .image = "nginx:alpine",
            .exposed_ports = &.{"80/tcp"},
            .wait_strategy = tc.wait.forPort("80/tcp"),
        };
        const ctr = try provider.runContainer(&req);
        try containers.append(alloc, ctr);
    }

    try std.testing.expectEqual(@as(usize, 3), containers.items.len);

    for (containers.items) |ctr| {
        const port = try ctr.mappedPort("80/tcp", alloc);
        try std.testing.expect(port > 0);
    }
}

// ---------------------------------------------------------------------------
// Test: GenericContainerShouldReturnRefOnError
// Mirrors: TestGenericContainerShouldReturnRefOnError in generic_test.go
// ---------------------------------------------------------------------------

test "GenericContainerShouldReturnRefOnError" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "nginx:alpine",
        .wait_strategy = .{
            .log = .{
                .log = "this string should not be present in the logs",
                .startup_timeout_ns = 2 * std.time.ns_per_s,
            },
        },
    };

    // createContainer + start() so we keep the ref even if start fails
    const ctr = try provider.createContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    // start() will timeout waiting for the log message
    const start_result = ctr.start();
    try std.testing.expectError(error.WaitStrategyTimeout, start_result);

    // Container ref is still valid — we can inspect it
    var inspected = try ctr.inspect();
    defer inspected.deinit();
    // The container exists (was created in Docker)
    try std.testing.expect(inspected.value.Id.len > 0);
}

// ---------------------------------------------------------------------------
// Test: ImageExists
// ---------------------------------------------------------------------------

test "ImageExists" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var client = tc.DockerClient.init(alloc, tc.docker_socket);
    defer client.deinit();

    // alpine:3 should exist after other tests pulled it; retry pull just in case
    try client.imagePull("alpine:3");

    const exists = try client.imageExists("alpine:3");
    try std.testing.expect(exists);

    const not_exists = try client.imageExists("this-image-does-not-exist-zig-test:latest");
    try std.testing.expect(!not_exists);
}

// ---------------------------------------------------------------------------
// Test: ContainerStopAndRestart
// ---------------------------------------------------------------------------

test "ContainerStopAndRestart" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 60" },
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    try std.testing.expect(try ctr.isRunning());

    // Stop — container should transition to "exited"
    try ctr.stop(null);
    try std.testing.expect(!(try ctr.isRunning()));
}

// ---------------------------------------------------------------------------
// Test: GenericReusableContainer
// Mirrors: TestGenericReusableContainer in generic_test.go
// ---------------------------------------------------------------------------

test "GenericReusableContainer" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    // Generate a unique container name for this test run.
    const ctr_name = try uniqueName(alloc, "reuse");
    defer alloc.free(ctr_name);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    // 1. Create the first container with the unique name.
    const greq1 = tc.GenericContainerRequest{
        .container_request = .{
            .image = "nginx:alpine",
            .exposed_ports = &.{"80/tcp"},
            .name = ctr_name,
            .wait_strategy = tc.wait.forPort("80/tcp"),
        },
        .started = true,
    };
    const ctr1 = try provider.runGenericContainer(&greq1);
    defer {
        ctr1.terminate() catch {};
        ctr1.deinit();
    }
    try std.testing.expect(try ctr1.isRunning());

    // 2. Trying to create another container with the same name (reuse=false)
    //    should fail with a Conflict error from Docker.
    const greq2 = tc.GenericContainerRequest{
        .container_request = .{
            .image = "nginx:alpine",
            .exposed_ports = &.{"80/tcp"},
            .name = ctr_name,
            .wait_strategy = .none,
        },
        .started = true,
        .reuse = false,
    };
    const result2 = provider.runGenericContainer(&greq2);
    try std.testing.expectError(error.Conflict, result2);

    // 3. With reuse=true the existing container is returned.
    const greq3 = tc.GenericContainerRequest{
        .container_request = .{
            .image = "nginx:alpine",
            .exposed_ports = &.{"80/tcp"},
            .name = ctr_name,
            .wait_strategy = tc.wait.forPort("80/tcp"),
        },
        .started = true,
        .reuse = true,
    };
    const ctr3 = try provider.runGenericContainer(&greq3);
    defer {
        // Same underlying container as ctr1; terminate once is enough
        ctr3.deinit();
    }
    try std.testing.expect(try ctr3.isRunning());
    // They wrap the same Docker container ID
    try std.testing.expectEqualStrings(ctr1.id, ctr3.id);
}

// ---------------------------------------------------------------------------
// Test: GenericReusableContainerRequiresName
// Mirrors: "reuse option with empty name" sub-test in generic_test.go
// ---------------------------------------------------------------------------

test "GenericReusableContainerRequiresName" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const greq = tc.GenericContainerRequest{
        .container_request = .{
            .image = "alpine:3",
            // name is null
        },
        .reuse = true,
    };
    const result = provider.runGenericContainer(&greq);
    try std.testing.expectError(error.ContainerNameRequired, result);
}

// ---------------------------------------------------------------------------
// Test: network/New
// Mirrors: TestNew in network/network_test.go
// ---------------------------------------------------------------------------

test "network: New" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const net_name = try uniqueName(alloc, "net-new");
    defer alloc.free(net_name);

    const net = try tc.network.newNetwork(alloc, &provider.client, .{
        .name = net_name,
        .driver = "bridge",
        .attachable = true,
    });
    defer {
        net.remove() catch {};
        net.deinit();
    }

    try std.testing.expectEqualStrings(net_name, net.name);
    try std.testing.expect(net.id.len > 0);
}

// ---------------------------------------------------------------------------
// Test: network/ContainerAttachedToNewNetwork
// Mirrors: TestContainerAttachedToNewNetwork in network/network_test.go
// ---------------------------------------------------------------------------

test "network: ContainerAttachedToNewNetwork" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const net_name = try uniqueName(alloc, "net-attach");
    defer alloc.free(net_name);

    const net = try tc.network.newNetwork(alloc, &provider.client, .{
        .name = net_name,
        .driver = "bridge",
    });
    defer {
        net.remove() catch {};
        net.deinit();
    }

    const aliases_slice = [_][]const u8{ "alias1", "alias2", "alias3" };
    const net_alias = tc.NetworkAlias{
        .network = net_name,
        .aliases = &aliases_slice,
    };

    const req = tc.ContainerRequest{
        .image = "nginx:alpine",
        .exposed_ports = &.{"80/tcp"},
        .networks = &.{net_name},
        .network_aliases = &.{net_alias},
        .wait_strategy = tc.wait.forPort("80/tcp"),
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    // Verify the container is on the expected network
    const container_nets = try ctr.networks(alloc);
    defer {
        for (container_nets) |n| alloc.free(n);
        alloc.free(container_nets);
    }
    try std.testing.expectEqual(@as(usize, 1), container_nets.len);
    try std.testing.expectEqualStrings(net_name, container_nets[0]);

    // Verify aliases
    const container_aliases = try ctr.networkAliases(net_name, alloc);
    defer {
        for (container_aliases) |a| alloc.free(a);
        alloc.free(container_aliases);
    }
    for (aliases_slice) |expected_alias| {
        var found = false;
        for (container_aliases) |a| {
            if (std.mem.eql(u8, a, expected_alias)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }

    // Container IP on the network should be non-empty
    const ip = try ctr.networkIP(net_name, alloc);
    defer alloc.free(ip);
    try std.testing.expect(ip.len > 0);
}

// ---------------------------------------------------------------------------
// Test: network/MultipleContainersInSameNetwork
// Mirrors: TestMultipleContainersInTheNewNetwork in network/network_test.go
// ---------------------------------------------------------------------------

test "network: MultipleContainersInSameNetwork" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const net_name = try uniqueName(alloc, "net-multi");
    defer alloc.free(net_name);

    const net = try tc.network.newNetwork(alloc, &provider.client, .{
        .name = net_name,
        .driver = "bridge",
    });
    defer {
        net.remove() catch {};
        net.deinit();
    }

    const req1 = tc.ContainerRequest{
        .image = "nginx:alpine",
        .networks = &.{net_name},
        .network_aliases = &.{tc.NetworkAlias{
            .network = net_name,
            .aliases = &.{"nginx1"},
        }},
        .wait_strategy = .none,
    };
    const req2 = tc.ContainerRequest{
        .image = "nginx:alpine",
        .networks = &.{net_name},
        .network_aliases = &.{tc.NetworkAlias{
            .network = net_name,
            .aliases = &.{"nginx2"},
        }},
        .wait_strategy = .none,
    };

    const c1 = try provider.runContainer(&req1);
    defer {
        c1.terminate() catch {};
        c1.deinit();
    }
    const c2 = try provider.runContainer(&req2);
    defer {
        c2.terminate() catch {};
        c2.deinit();
    }

    const nets1 = try c1.networks(alloc);
    defer {
        for (nets1) |n| alloc.free(n);
        alloc.free(nets1);
    }
    const nets2 = try c2.networks(alloc);
    defer {
        for (nets2) |n| alloc.free(n);
        alloc.free(nets2);
    }

    try std.testing.expectEqual(@as(usize, 1), nets1.len);
    try std.testing.expectEqual(@as(usize, 1), nets2.len);
    try std.testing.expectEqualStrings(net_name, nets1[0]);
    try std.testing.expectEqualStrings(net_name, nets2[0]);
}

// ---------------------------------------------------------------------------
// Test: network/ContainerIPs — container on multiple networks has multiple IPs
// Mirrors: TestContainerIPs in network/network_test.go
// ---------------------------------------------------------------------------

test "network: ContainerIPs" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const net_name = try uniqueName(alloc, "net-ips");
    defer alloc.free(net_name);

    const net = try tc.network.newNetwork(alloc, &provider.client, .{
        .name = net_name,
        .driver = "bridge",
    });
    defer {
        net.remove() catch {};
        net.deinit();
    }

    // Attach to both the custom network and the default bridge network.
    const req = tc.ContainerRequest{
        .image = "nginx:alpine",
        .exposed_ports = &.{"80/tcp"},
        .networks = &.{ net_name, "bridge" },
        .network_aliases = &.{tc.NetworkAlias{
            .network = net_name,
            .aliases = &.{"nginx"},
        }},
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const nets = try ctr.networks(alloc);
    defer {
        for (nets) |n| alloc.free(n);
        alloc.free(nets);
    }
    // Container should be on at least 2 networks
    try std.testing.expect(nets.len >= 2);
}

// ---------------------------------------------------------------------------
// Test: WaitForExecStrategy
// ---------------------------------------------------------------------------

test "WaitForExecStrategy" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    // Wait for the container to have the /tmp/ready file created.
    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 1; touch /tmp/ready; sleep 60" },
        .wait_strategy = .{
            .exec = .{
                .cmd = &.{ "test", "-f", "/tmp/ready" },
                .expected_exit_code = 0,
                .startup_timeout_ns = 15 * std.time.ns_per_s,
                .poll_interval_ns = 200 * std.time.ns_per_ms,
            },
        },
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    try std.testing.expect(try ctr.isRunning());
}

// ---------------------------------------------------------------------------
// Test: ContainerWithEnvironmentVariables
// ---------------------------------------------------------------------------

test "ContainerWithEnvironmentVariables" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "alpine:3",
        .cmd = &.{ "sh", "-c", "sleep 60" },
        .env = &.{"MY_VAR=hello-from-env"},
        .wait_strategy = .none,
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const result = try ctr.exec(&.{ "sh", "-c", "echo $MY_VAR" });
    defer alloc.free(result.output);

    try std.testing.expectEqual(@as(i64, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "hello-from-env") != null);
}

// ---------------------------------------------------------------------------
// Test: ContainerEndpoint
// ---------------------------------------------------------------------------

test "ContainerEndpoint" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    var provider = tc.DockerProvider.init(alloc);
    defer provider.deinit();

    const req = tc.ContainerRequest{
        .image = "nginx:alpine",
        .exposed_ports = &.{"80/tcp"},
        .wait_strategy = tc.wait.forPort("80/tcp"),
    };

    const ctr = try provider.runContainer(&req);
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    const ep = try ctr.endpoint("80/tcp", "http", alloc);
    defer alloc.free(ep);

    // Should be "http://localhost:<port>"
    try std.testing.expect(std.mem.startsWith(u8, ep, "http://localhost:"));
}

// ---------------------------------------------------------------------------
// Test: TopLevelRunFunction
// Mirrors: tc.run() convenience API
// ---------------------------------------------------------------------------

test "TopLevelRunFunction" {
    const alloc = std.testing.allocator;
    try skipIfNoDocker(alloc);

    defer tc.deinitProvider();

    const ctr = try tc.run(alloc, "alpine:3", .{
        .cmd = &.{ "sh", "-c", "sleep 60" },
        .wait_strategy = .none,
    });
    defer {
        ctr.terminate() catch {};
        ctr.deinit();
    }

    try std.testing.expect(try ctr.isRunning());
}
