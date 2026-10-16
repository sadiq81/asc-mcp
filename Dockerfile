# Remote (Streamable HTTP) image for asc-mcp, e.g. for Google Cloud Run.
# asc-mcp itself speaks stdio; supergateway exposes it over HTTP.
# Build and runtime both use Debian bookworm so glibc versions match.

FROM swift:6.2-bookworm AS build
WORKDIR /src
COPY . .
RUN swift build -c release --static-swift-stdlib --disable-automatic-resolution \
    && mkdir -p /out \
    && cp .build/release/asc-mcp /out/ \
    && cp -R .build/release/asc-mcp_asc-mcp.resources /out/

FROM node:22-bookworm-slim
# libcurl backs URLSession on Linux; ca-certificates is needed for HTTPS to Apple.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libcurl4 ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g supergateway@4.2.0 \
    && npm cache clean --force

COPY --from=build /out/ /app/
USER node

# Credentials: ASC_KEY_ID, ASC_ISSUER_ID, ASC_PRIVATE_KEY (PEM contents).
# MCP_PATH: secret URL path; it is the only thing standing between the internet and your API key.
# ASC_MCP_ARGS: optional server flags, e.g. "--read-only" or "--workers apps,versions,builds".
# Uploads may only read from /tmp/uploads (normally empty on a remote host).
ENV ASC_MCP_UPLOAD_DIRS=/tmp/uploads \
    ASC_MCP_ARGS=""

CMD test -n "$MCP_PATH" || { echo "MCP_PATH must be set" >&2; exit 1; }; \
    exec supergateway \
      --stdio "/app/asc-mcp $ASC_MCP_ARGS" \
      --outputTransport streamableHttp \
      --port "${PORT:-8080}" \
      --streamableHttpPath "/${MCP_PATH}" \
      --logLevel none
