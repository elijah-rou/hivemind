FROM ubuntu:22.04

RUN apt-get update && apt-get install -y \
    containerd \
    curl \
    build-essential \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Install Rust
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /hivemind/worker

# Copy source
COPY worker/ /hivemind/worker/

# Build with containerd-integration feature
RUN cargo build --release --features containerd-integration

# Start containerd and run tests
COPY tests/containerd/run.sh /run.sh
RUN chmod +x /run.sh
CMD ["/run.sh"]
