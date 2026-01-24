FROM --platform=linux/amd64 ubuntu:24.04 AS build

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    autoconf automake build-essential cmake curl git libtool pkg-config \
    yasm nasm ca-certificates \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# ---- Build fdk-aac ----
RUN git clone --depth=1 https://github.com/mstorsjo/fdk-aac.git /tmp/fdk-aac && \
    cd /tmp/fdk-aac && \
    autoreconf -fiv && \
    ./configure --prefix=/opt/fdk && \
    make -j"$(nproc)" && \
    make install

# ---- Build ffmpeg (WITH HTTPS) ----
RUN git clone --depth=1 --branch n7.1 https://github.com/FFmpeg/FFmpeg.git /tmp/ffmpeg && \
    cd /tmp/ffmpeg && \
    PKG_CONFIG_PATH=/opt/fdk/lib/pkgconfig ./configure \
      --prefix=/opt/ffmpeg \
      --extra-cflags="-I/opt/fdk/include" \
      --extra-ldflags="-L/opt/fdk/lib" \
      --enable-gpl \
      --enable-nonfree \
      --enable-libfdk-aac \
      --enable-openssl \
      --disable-debug \
      --disable-doc \
      --disable-ffplay && \
    make -j"$(nproc)" && \
    make install

# ---- Shaka Packager binary ----
RUN curl -fsSL \
    https://github.com/shaka-project/shaka-packager/releases/latest/download/packager-linux-x64 \
    -o /opt/packager && chmod +x /opt/packager


# =========================
# Final runtime image
# =========================
FROM --platform=linux/amd64 ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash tini \
    libssl3 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/ffmpeg /opt/ffmpeg
COPY --from=build /opt/fdk /opt/fdk
COPY --from=build /opt/packager /usr/local/bin/packager

ENV PATH="/opt/ffmpeg/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/fdk/lib:/opt/ffmpeg/lib"

WORKDIR /app
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/bin/bash", "/app/entrypoint.sh"]