FROM savonet/liquidsoap:main

# Switch to root to install packages
USER root

# Install additional packages - liquidsoap image is Debian-based
RUN apt-get update && apt-get install -y \
    ffmpeg \
    nodejs \
    npm \
    bash \
    coreutils \
    curl \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package.json /app/package.json
RUN npm install --omit=dev

COPY entrypoint.sh /app/entrypoint.sh
COPY healthcheck.sh /app/healthcheck.sh
COPY liquidsoap.liq /app/liquidsoap.liq
COPY stitcher.js /app/stitcher.js

RUN chmod +x /app/entrypoint.sh /app/healthcheck.sh

ENV TZ=UTC

ENTRYPOINT ["/app/entrypoint.sh"]