FROM alpine:latest AS builder

# Install core build tools and static variants of required libraries.
# pin versions are intentionally not used so we always pick up the latest
# stable Alpine packages; bump Alpine tag (e.g. alpine:3.20) if you need
# reproducibility.
RUN apk add --no-cache \
    bash \
    cmake \
    curl \
    g++ \
    gcc \
    gettext-dev \
    gettext-static \
    git \
    gperf \
    libtermkey-dev \
    libtermkey-static \
    libuv-dev \
    libuv-static \
    libvterm-dev \
    libvterm-static \
    lua5.1-bitop \
    lua5.1-lpeg \
    luajit-dev \
    make \
    msgpack-c-dev \
    musl-dev \
    ncurses-dev \
    ncurses-static \
    samurai \
    tree-sitter-dev \
    tree-sitter-static \
    unibilium-dev \
    unibilium-static

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
FROM alpine:latest AS runtime
RUN apk add --no-cache tar
COPY --from=builder /neovim/build/bin/nvim /out/nvim
COPY --from=builder /neovim/runtime /out/runtime
# Print ldd result into a file so the workflow can show it.
RUN ldd /out/nvim || true

# ---- minimal export stage ----------------------------------------------------
# Final image is 'scratch' so `docker create` + `docker cp` gives us only the
# artifacts we want, with no extra distro files.
FROM scratch
COPY --from=runtime /out /out
