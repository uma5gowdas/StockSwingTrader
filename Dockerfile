# StockSwingTrader v6.3 - portable Linux image (Debian 13 "trixie", Python 3.12)
#
# Build (core only, the default):
#   docker build -t sst .
# Build with the Python 3.12 agent layer (.venv-agents, ~1.2 GB more):
#   docker build --build-arg WITH_AGENTS=1 -t sst:agents .
#
# Run the offline test suite (default command):
#   docker run --rm sst
# Run the CLI:
#   docker run --rm sst ./StockSwingTrader_Agent.sh --symbols AAPL
#
# Configuration is NEVER baked into the image (config.sh is excluded by
# .dockerignore; the image only has config.sh copied from config.template.sh by
# setup.sh, which holds no keys). Provide keys at run time, either as
# environment variables:
#   docker run --rm -e ALPACA_API_KEY=... -e ALPACA_SECRET_KEY=... sst ...
# or by mounting your own config file read-only:
#   docker run --rm -v "$PWD/config.sh:/run/sst/config.sh:ro" \
#     -e SST_CONFIG_FILE=/run/sst/config.sh sst ./StockSwingTrader_Agent.sh --check-account
# Keep ALPACA_BASE_URL on https://paper-api.alpaca.markets.
FROM python:3.12-slim-trixie

ARG WITH_AGENTS=0

# System tools needed by the bash CLI, setup.sh and the tests.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash git jq bc curl perl ca-certificates tzdata nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Non-root user owns the app directory.
RUN useradd --create-home --shell /bin/bash sst \
    && mkdir -p /app \
    && chown sst:sst /app

USER sst
WORKDIR /app

COPY --chown=sst:sst . .

# .venv (core requirements), npm ci for backend/frontend, config.sh from the
# template, ML model training; .venv-agents only with WITH_AGENTS=1.
RUN ./setup.sh --non-interactive --skip-smoke $( [ "$WITH_AGENTS" = 1 ] && echo --with-agents )

ENV SST_OFFLINE=1

CMD ["bash", "tests/test_runner.sh"]
