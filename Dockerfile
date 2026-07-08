FROM termux/termux-docker:latest AS builder

# Temporarily use root to install packages and remove the shared libiconv
USER root
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
    file \
    libiconv-static \
    && rm -f /data/data/com.termux/files/usr/lib/libiconv.so*

# Switch back to the termux user
USER 1000:1000

# Allow overriding the Neovim ref (tag / branch / commit) at build time.
ARG NVIM_REF=stable
RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim.git /data/data/com.termux/files/home/neovim

WORKDIR /data/data/com.termux/files/home/neovim

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
FROM termux/termux-docker:latest AS runtime
USER 1000:1000
RUN pkg update && pkg install -y tar file
RUN mkdir -p /data/data/com.termux/files/home/out
COPY --from=builder /data/data/com.termux/files/home/neovim/build/bin/nvim /data/data/com.termux/files/home/out/nvim
COPY --from=builder /data/data/com.termux/files/home/neovim/runtime /data/data/com.termux/files/home/out/runtime
RUN file /data/data/com.termux/files/home/out/nvim > /data/data/com.termux/files/home/out/file-info.txt && \
    { ldd /data/data/com.termux/files/home/out/nvim 2>&1 || true; } > /data/data/com.termux/files/home/out/ldd.txt

# ---- minimal export stage ----------------------------------------------------
FROM scratch
COPY --from=runtime /data/data/com.termux/files/home/out /out
CMD ["/out/nvim"]
