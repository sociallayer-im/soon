# syntax=docker/dockerfile:1
# check=error=true

ARG RUBY_VERSION=4.0.5
# Pin the base filesystem: republishing a Ruby tag must not invalidate every layer.
ARG RUBY_IMAGE=docker.io/library/ruby:4.0.5-slim@sha256:42ad5227a4b2758f32563b34b5967e1055e75c80243eef04e6d2572887d1dec4
ARG BUN_IMAGE=oven/bun:1.3.14@sha256:e10577f0db68676a7024391c6e5cb4b879ebd17188ab750cf10024a6d700e5c4

FROM ${RUBY_IMAGE} AS base
ARG RUBY_VERSION
ARG TARGETARCH
WORKDIR /rails

# Keep apt downloads outside image layers, including when package lists change.
RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN --mount=type=cache,id=surf-apt-cache-${RUBY_VERSION}-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=surf-apt-lists-${RUBY_VERSION}-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so

ENV RAILS_ENV=production \
    BUNDLE_DEPLOYMENT=1 \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_WITHOUT=development:test \
    LD_PRELOAD=/usr/local/lib/libjemalloc.so

# Independent of Ruby dependencies; ordinary backend changes do not reinstall Bun packages.
FROM ${BUN_IMAGE} AS javascript-deps
WORKDIR /rails
COPY package.json bun.lock ./
RUN --mount=type=cache,id=surf-bun-1.3.14,target=/root/.bun/install/cache,sharing=locked \
    bun install --frozen-lockfile

FROM javascript-deps AS javascript-build
COPY bun.config.js ./
COPY app/javascript ./app/javascript
COPY app/assets ./app/assets
COPY app/views ./app/views
COPY app/helpers ./app/helpers
RUN bun run build && bun run build:css

FROM base AS gems
ARG BUNDLE_JOBS=2
# Native dependencies for pg, psych and siwe-rb's vendored libsecp256k1.
RUN --mount=type=cache,id=surf-apt-cache-${RUBY_VERSION}-${TARGETARCH},target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=surf-apt-lists-${RUBY_VERSION}-${TARGETARCH},target=/var/lib/apt/lists,sharing=locked \
    apt-get update -qq && \
    apt-get install --no-install-recommends -y \
      build-essential git libpq-dev libyaml-dev pkg-config autoconf automake libtool libgmp-dev
COPY Gemfile Gemfile.lock ./
# Preserve compiled extensions as well as downloads when Gemfile.lock changes.
# Copy OUT of the mount: cache mounts are not part of the resulting image.
RUN --mount=type=cache,id=surf-production-gems-${RUBY_VERSION}-${TARGETARCH},target=/var/cache/surf-bundle,sharing=locked \
    BUNDLE_PATH=/var/cache/surf-bundle bundle install --jobs=${BUNDLE_JOBS} --retry=3 && \
    BUNDLE_PATH=/var/cache/surf-bundle bundle clean --force && \
    cp -a /var/cache/surf-bundle/. "${BUNDLE_PATH}/" && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 2 --gemfile

FROM gems AS build
COPY . .
COPY --from=javascript-build /rails/app/assets/builds ./app/assets/builds
# JavaScript/CSS were built once above; Rails only fingerprints the finished assets.
RUN bundle exec bootsnap precompile -j 2 app/ lib/ && \
    SECRET_KEY_BASE_DUMMY=1 SKIP_JS_BUILD=1 SKIP_CSS_BUILD=1 ./bin/rails assets:precompile

FROM base AS runtime
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
# Gems are read-only runtime inputs: avoid rewriting ownership on every gem file.
COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY --chown=1000:1000 --from=build /rails /rails
USER 1000:1000
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
