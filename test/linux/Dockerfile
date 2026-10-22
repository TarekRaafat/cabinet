# The Linux the test suite runs on (npm run test:linux): Debian with the tools the kit needs.
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash git openssl ca-certificates nodejs npm procps zsh \
    && rm -rf /var/lib/apt/lists/*
RUN useradd -m tester
USER tester
