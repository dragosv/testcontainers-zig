# Docker-in-Docker (DinD) patterns

When running Testcontainers in CI environments that don't have Docker natively available, you can use Docker-in-Docker patterns.

## GitHub Actions

GitHub-hosted runners include Docker, so DinD is not typically needed. See [GitHub Actions](github_actions.md).

## GitLab CI with DinD service

```yaml
test:
  stage: test
  image: debian:bookworm-slim
  services:
    - docker:dind
  variables:
    DOCKER_HOST: tcp://docker:2375
    DOCKER_TLS_CERTDIR: ""
  before_script:
    - apt-get update && apt-get install -y curl xz-utils docker.io
    - curl -L https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz | tar xJ
    - export PATH="$PWD/zig-linux-x86_64-0.15.2:$PATH"
  script:
    - zig build test --summary all
    - zig build integration-test --summary all
```

## Generic Docker-in-Docker

If you're running inside a Docker container and need to use Testcontainers, mount the Docker socket:

```bash
docker run -v /var/run/docker.sock:/var/run/docker.sock \
    -v $(pwd):/workspace -w /workspace \
    my-zig-builder:latest \
    zig build integration-test --summary all
```

## Environment variables

When using DinD or remote Docker hosts, set:

```bash
export DOCKER_HOST=tcp://docker:2375
```

Testcontainers for Zig respects the `DOCKER_HOST` environment variable and will connect to the specified Docker daemon instead of the default Unix socket.

!!! warning

    When using `DOCKER_HOST` with a TCP address, ensure the Docker daemon is configured to accept unauthenticated connections or configure TLS appropriately.
