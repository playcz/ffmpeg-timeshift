FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl bash tini \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# --- Install Shaka Packager ---
# This installs the official Linux binary release
RUN mkdir -p /opt/shaka && \
    curl -fsSL \
      https://github.com/shaka-project/shaka-packager/releases/latest/download/packager-linux-x64 \
      -o /opt/shaka/packager && \
    chmod +x /opt/shaka/packager && \
    ln -s /opt/shaka/packager /usr/local/bin/packager

WORKDIR /app
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/entrypoint.sh"]
