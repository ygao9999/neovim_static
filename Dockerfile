# Pin Alpine to a specific version for reproducibility.
# `alpine:latest` can roll forward and break builds when packages get renamed
# (e.g. some `-static` subpackages were moved between 3.20 and 3.21).
# Bump deliberately when you've tested a newer version works.
FROM alpine:3.20 AS builder

# Refresh the package index. The base image's index can be stale by the time
# CI runs, which causes spurious "package not found" errors.
RUN apk update

# --- Group 1: core build tools (always present in main) ---------------------
RUN apk add --no-cache \
    bash \
    cmake \
    curl \
    g++ \
    gcc \
    git \
    gperf \
    make \
    samurai \
    musl-dev \
    unzip \
    patch \
    pkgconf \
    autoconf \
    automake \
    libtool \
    coreutils

# --- Group 2: main-repo dev+static pairs ------------------------------------
RUN apk add --no-cache \
    gettext-dev \
    gettext-static \
    libuv-dev \
    libuv-static \
    ncurses-dev \
    ncurses-static



# Allow overriding the Neovim ref (tag / branch / commit) at build time.
# Defaults to 'stable'. Example: docker build --build-arg NVIM_REF=v0.10.4 .
ARG NVIM_REF=stable
RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim.git /neovim

WORKDIR /neovim

# Build Neovim in two stages so a deps failure is isolated and easy to read.
#
# Why split: `make` (default target) builds `deps` then `nvim`. When the deps
# phase fails, the error log mixes ninja output from ~10 parallel dep builds
# (luajit, libuv, libvterm, libtermkey, unibilium, tree-sitter, msgpack, ...).
# Splitting forces the deps phase to run alone, so the real error is visible.
#
# Why CMAKE_BUILD_PARALLEL_LEVEL (not NINJA_FLAGS): Neovim's Makefile drives
# deps via `cmake --build .deps/build`, and cmake 3.12+ reads the
# CMAKE_BUILD_PARALLEL_LEVEL env var to decide how many jobs to run. Setting
# NINJA_FLAGS has NO effect here — that was my previous mistake, which is why
# deps were still running at full parallel and the real error stayed buried.
ENV CMAKE_BUILD_PARALLEL_LEVEL=2
# Verbose build so we can see the exact compile/link command that fails.
ENV VERBOSE=1

# Stage 1: third-party deps. This is the slow, failure-prone part.
#
# Retry up to 3 times. The most common transient failure is a git clone or
# tarball download hitting GitHub's rate limit, which a single retry usually
# fixes. On final failure, dump the build logs so the GHA log shows exactly
# which dep failed.
RUN set -e; \
    for attempt in 1 2 3; do \
      echo "===== deps build attempt $attempt/3 ====="; \
      if make CMAKE_BUILD_TYPE=Release \
              CMAKE_EXTRA_FLAGS="-DSTATIC_BUILD=1 -DCMAKE_VERBOSE_MAKEFILE=ON" \
              deps; then \
        echo "===== deps OK on attempt $attempt ====="; \
        break; \
      fi; \
      if [ "$$attempt" = "3" ]; then \
        echo "::error::deps build failed after 3 attempts. Dumping build logs:"; \
        echo "----- .deps/build/CMakeFiles/CMakeError.log -----"; \
        tail -n 200 /neovim/.deps/build/CMakeFiles/CMakeError.log 2>/dev/null || true; \
        echo "----- .deps/build/CMakeFiles/CMakeOutput.log -----"; \
        tail -n 100 /neovim/.deps/build/CMakeFiles/CMakeOutput.log 2>/dev/null || true; \
        echo "----- last 300 lines of .deps/build build output -----"; \
        find /neovim/.deps/build -name 'build.log' -o -name '*.log' 2>/dev/null | head -n 5; \
        echo "----- per-dep build directories -----"; \
        ls -la /neovim/.deps/build/src/ 2>/dev/null || true; \
        exit 1; \
      fi; \
      echo "deps attempt $attempt failed, retrying in 10s..."; \
      sleep 10; \
    done

# Stage 2: nvim itself. Small .c files, safe to parallelize aggressively.
# Still retry once — rarely a transient gcc OOM on small runners.
RUN set -e; \
    for attempt in 1 2 3; do \
      echo "===== nvim build attempt $attempt/3 ====="; \
      if make CMAKE_BUILD_TYPE=Release \
              CMAKE_EXTRA_FLAGS="-DSTATIC_BUILD=1 -DCMAKE_VERBOSE_MAKEFILE=ON" \
              -j"$(nproc)"; then \
        echo "===== nvim OK on attempt $attempt ====="; \
        break; \
      fi; \
      if [ "$$attempt" = "3" ]; then \
        echo "::error::nvim build failed after 3 attempts"; \
        exit 1; \
      fi; \
      echo "nvim attempt $attempt failed, retrying in 10s..."; \
      sleep 10; \
    done

# ---- runtime packaging stage -------------------------------------------------
# We need the runtime/ directory (syntax files, lua stdlib, autoload scripts)
# so the static binary is usable on a host that has no Neovim installed.
# Use a small alpine image to copy runtime + binary into a tarball-friendly fs.
FROM alpine:3.20 AS runtime
RUN apk add --no-cache tar file
COPY --from=builder /neovim/build/bin/nvim /out/nvim
COPY --from=builder /neovim/runtime /out/runtime
# Capture static-link info as a file we can read out later.
RUN file /out/nvim > /out/file-info.txt && \
    { ldd /out/nvim 2>&1 || true; } > /out/ldd.txt

# ---- minimal export stage ----------------------------------------------------
# Final image is 'scratch' so `docker create` + `docker cp` gives us only the
# artifacts we want, with no extra distro files.
FROM scratch
COPY --from=runtime /out /out
