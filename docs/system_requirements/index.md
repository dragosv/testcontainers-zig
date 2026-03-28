# System requirements

Testcontainers for Zig has the following system requirements:

| Requirement     | Minimum version      |
|-----------------|----------------------|
| Zig             | 0.15.2               |
| macOS           | 13.0 (Ventura)       |
| Linux           | Ubuntu 22.04+        |
| Docker          | 20.10+               |

## Zig

Testcontainers for Zig is built with Zig 0.15.2 and uses the Zig Build System (`build.zig` + `build.zig.zon`). No external dependencies are required.

## Docker

A Docker-compatible container runtime is required:

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS, Windows, Linux)
- [Docker Engine](https://docs.docker.com/engine/) (Linux)
- [Rancher Desktop](https://rancherdesktop.io/) (macOS, Windows, Linux)
- [Podman](https://podman.io/) with Docker-compatible socket

The library communicates with Docker over its Unix domain socket (`/var/run/docker.sock`). Set the `DOCKER_HOST` environment variable if your Docker socket is at a non-standard location.

## Checking your setup

Verify Docker is available:

```bash
docker info
```

Run the tests:

```bash
zig build test --summary all                # Unit tests (no Docker required)
zig build integration-test --summary all    # Integration tests (requires Docker)
```

## CI/CD

Testcontainers for Zig works in CI environments that provide Docker access. See:

- [GitHub Actions](ci/github_actions.md)
- [GitLab CI/CD](ci/gitlab_ci.md)
- [Docker-in-Docker patterns](ci/dind_patterns.md)
