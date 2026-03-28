# GitLab CI/CD

Testcontainers for Zig can run on GitLab CI/CD using Docker-in-Docker or a shell executor with Docker installed.

## Docker-in-Docker

```yaml
stages:
  - test

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

## Shell executor

If your GitLab runner uses the shell executor with Docker already installed:

```yaml
test:
  stage: test
  tags:
    - shell
  before_script:
    - curl -L https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz | tar xJ
    - export PATH="$PWD/zig-linux-x86_64-0.15.2:$PATH"
  script:
    - zig build test --summary all
    - zig build integration-test --summary all
```
