FROM jrottenberg/ffmpeg:7.1-ubuntu

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl bash tini \
    && rm -rf /var/lib/apt/lists/*

RUN curl -fsSL \
      https://github.com/shaka-project/shaka-packager/releases/latest/download/packager-linux-x64 \
      -o /usr/local/bin/packager && \
    chmod +x /usr/local/bin/packager

WORKDIR /app
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash", "/app/entrypoint.sh"]