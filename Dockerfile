# Build Neovim natively for Termux using the official termux-docker multi-arch image.
# This produces a binary dynamically linked to Android's Bionic libc, which perfectly
# supports dlopen (for plugins like tree-sitter) and avoids seccomp SIGSYS crashes.
FROM ghcr.io/termux/termux-docker:latest AS builder

# Update and install native Termux build tools
RUN pkg update && pkg install -y \
    bash \
    cmake \
    curl \
    clang \
    git \
    make \
    ninja \
    unzip \
    patch \
    pkg-config \
    autoconf \
    automake \
    libtool \
    coreutils \
    gettext \
    file

# Allow overriding the Neovim ref (tag / branch / commit) at build time.
ARG NVIM_REF=stable
# termux-docker defaults to user 'builder' in /home/builder
RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim.git /home/builder/neovim

WORKDIR /home/builder/neovim

ENV CMAKE_BUILD_PARALLEL_LEVEL=2
ENV VERBOSE=1

# Stage 1: third-party deps.
# Note: We REMOVED -DSTATIC_BUILD=1. We want dependencies compiled statically into nvim,
# but the final binary must dynamically link to Termux's libc.so and libdl.so.
RUN set -e; \
    for attempt in 1 2 3; do \
      echo "===== deps build attempt $attempt/3 ====="; \
      if make CMAKE_BUILD_TYPE=Release \
              CMAKE_EXTRA_FLAGS="-DCMAKE_VERBOSE_MAKEFILE=ON" \
              deps; then \
        echo "===== deps OK on attempt $attempt ====="; \
        break; \
      fi; \
      if [ "$$attempt" = "3" ]; then \
        echo "::error::deps build failed after 3 attempts"; \
        exit 1; \
      fi; \
      echo "deps attempt $attempt failed, retrying in 10s..."; \
      sleep 10; \
    done

# Stage 2: nvim itself.
RUN set -e; \
    for attempt in 1 2 3; do \
      echo "===== nvim build attempt $attempt/3 ====="; \
      if make CMAKE_BUILD_TYPE=Release \
              CMAKE_EXTRA_FLAGS="-DCMAKE_VERBOSE_MAKEFILE=ON" \
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
FROM ghcr.io/termux/termux-docker:latest AS runtime
RUN pkg update && pkg install -y tar file
COPY --from=builder /home/builder/neovim/build/bin/nvim /out/nvim
COPY --from=builder /home/builder/neovim/runtime /out/runtime
# Capture dynamic-link info as a file we can read out later.
RUN file /out/nvim > /out/file-info.txt && \
    { ldd /out/nvim 2>&1 || true; } > /out/ldd.txt

# ---- minimal export stage ----------------------------------------------------
# Final image is 'scratch' so `docker create` + `docker cp` gives us only the
# artifacts we want, with no extra distro files.
FROM scratch
COPY --from=runtime /out /out
CMD ["/out/nvim"]
