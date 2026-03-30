# GitHub Actions

Testcontainers for Zig works out of the box with GitHub Actions. GitHub-hosted runners include Docker pre-installed.

## Example workflow

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Run unit tests
        run: zig build test --summary all

      - name: Run integration tests
        run: zig build integration-test --summary all
```

## Notes

- GitHub-hosted Ubuntu runners have Docker pre-installed — no additional setup is required.
- The `mlugg/setup-zig` action installs the specified Zig version.
- Unit tests (`zig build test`) do not require Docker. Integration tests (`zig build integration-test`) do.

## macOS runners

```yaml
  test-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Zig
        uses: mlugg/setup-zig@v2
        with:
          version: 0.15.2

      - name: Install Docker
        run: brew install --cask docker

      - name: Run unit tests
        run: zig build test --summary all
```

!!! note

    macOS runners do not have Docker pre-installed. You need to install Docker Desktop via Homebrew or similar.
