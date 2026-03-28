# Contributing to Documentation

The Testcontainers for Zig documentation lives in the `docs/` directory of the repository.

## Structure

```
docs/
├── index.md                        # Landing page
├── contributing.md                  # Contributing guide
├── contributing_docs.md             # This file
├── quickstart/
│   └── index.md                    # Getting started guide
├── features/
│   ├── creating_container.md       # ContainerRequest API
│   ├── creating_image.md           # Image pulling and management
│   ├── networking.md               # Ports and networks
│   ├── configuration.md            # Docker host and configuration
│   ├── garbage_collector.md        # Container cleanup patterns
│   ├── best_practices.md           # Recommendations
│   ├── connection_strings.md       # Connection string reference
│   ├── low_level_api.md            # DockerClient access
│   └── wait/
│       └── introduction.md         # Wait strategies
├── modules/
│   ├── index.md                    # Module overview
│   ├── postgres.md                 # PostgreSQL module
│   ├── mysql.md                    # MySQL module
│   ├── redis.md                    # Redis module
│   └── mongodb.md                  # MongoDB module
├── system_requirements/
│   ├── index.md                    # Zig, Docker, and OS requirements
│   └── ci/
│       ├── github_actions.md       # GitHub Actions setup
│       ├── gitlab_ci.md            # GitLab CI/CD setup
│       └── dind_patterns.md        # Docker-in-Docker patterns
├── examples/
│   └── index.md                    # Usage examples
└── test_frameworks/
    └── zig_test.md                 # Zig test integration patterns
```

## Guidelines

- Use Zig code examples — not Swift, Go, Java, or other languages.
- All code examples must use the actual testcontainers-zig API (`ContainerRequest` structs, `DockerProvider`, etc.).
- Ensure examples are consistent with the actual API in `src/`.
- Use fenced code blocks with the `zig` language identifier.
- Follow the [testcontainers-go documentation](https://golang.testcontainers.org/) style:
    - Each page should follow: Introduction → Usage example → Reference tables → Examples.
    - Module pages use: Introduction → Adding dependency → Usage example → Module Reference → Examples.
    - Use tables for API reference (parameters, methods, options).
    - Use admonitions (`!!! tip`, `!!! warning`, `!!! note`) for callouts.

## Adding a new page

1. Create the Markdown file in the appropriate directory.
2. Follow the structure of existing pages in the same section.
3. Cross-link to related pages where appropriate.
4. Verify all code samples are consistent with the current API.

## Adding a new module page

When a new container module is added to `src/modules/`, create a corresponding documentation page in `docs/modules/`:

1. Copy the structure from an existing module page (e.g., `postgres.md`).
2. Fill in: Introduction, Adding the dependency, Usage example, Module Reference (Options table, Container Methods table, Wait Strategy), and Examples.
3. Add the module to the table in `docs/modules/index.md`.
4. Cross-link from `docs/features/connection_strings.md` if it provides a connection string method.
