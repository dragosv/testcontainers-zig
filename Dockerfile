FROM ubuntu:24.04
RUN apt-get update && apt-get install -y curl xz-utils
RUN curl -O https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz && \
    tar xf zig-aarch64-linux-0.15.2.tar.xz && \
    mv zig-aarch64-linux-0.15.2 /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig
WORKDIR /app
COPY . .
CMD ["zig", "build", "integration-test", "--summary", "all"]
