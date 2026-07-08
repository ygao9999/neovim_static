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
    musl-dev

# --- Group 2: main-repo dev+static pairs ------------------------------------
RUN apk add --no-cache \
    gettext-dev \
    gettext-static \
    libuv-dev \
    libuv-static \
    ncurses-dev \
    ncurses-static

# --- Group 3: community-repo dev+static pairs -------------------------------
# NOTE: libtermkey and unibilium do NOT ship separate -static subpackages in
# Alpine — the .a files are bundled inside the -dev package. Listing a
# `libtermkey-static` or `unibilium-static` here makes apk fail with
# "unable to select packages" (exit code 2). Do not add them.
RUN apk add --no-cache \
    libtermkey-dev \
    libvterm-dev \
    libvterm-static \
    tree-sitter-dev \
    tree-sitter-static \
    unibilium-dev \
    msgpack-c-dev

# --- Group 4: Lua runtime + dev ---------------------------------------------
RUN apk add --no-cache \
    luajit-dev \
    lua5.1-bitop \
    lua5.1-lpeg

# Allow overriding the Neovim ref (tag / branch / commit) at build time.
# Defaults to 'stable'. Example: docker build --build-arg NVIM_REF=v0.10.4 .
ARG NVIM_REF=stable
RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim.git /neovim

WORKDIR /neovim

# Build Neovim with the static build flag and native optimizations.
# CMAKE_INSTALL_PREFIX is left at the default (/usr/local) because we only
# copy the compiled binary out of the image; install steps are skipped.
RUN make CMAKE_BUILD_TYPE=Release CMAKE_EXTRA_FLAGS="-DSTATIC_BUILD=1" -j"$(nproc)"

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
