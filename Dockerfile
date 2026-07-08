FROM termux/termux-docker:latest AS builder

USER 1000:1000

# 安装依赖（包括 libiconv-static）
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
    libiconv-static

ARG NVIM_REF=stable
RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim.git /data/data/com.termux/files/home/neovim

WORKDIR /data/data/com.termux/files/home/neovim

# ========== 关键补丁：强制使用静态 libiconv ==========
# 将 Neovim 的 CMakeLists.txt 中对 iconv 的查找和链接替换为静态库路径
RUN sed -i 's/find_package(Iconv REQUIRED)/# find_package(Iconv REQUIRED)/' CMakeLists.txt && \
    sed -i 's/target_link_libraries(nvim PRIVATE $<BUILD_INTERFACE:Iconv::Iconv>)/target_link_libraries(nvim PRIVATE \/data\/data\/com.termux\/files\/usr\/lib\/libiconv.a)/' src/nvim/CMakeLists.txt

# =========================================================

ENV CMAKE_BUILD_PARALLEL_LEVEL=2
ENV VERBOSE=1

# Stage 1: deps
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

# Stage 2: nvim
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

# ---- runtime ----
FROM termux/termux-docker:latest AS runtime
USER 1000:1000
RUN termux-change-repo || true
RUN pkg update && pkg install -y tar file
RUN mkdir -p /data/data/com.termux/files/home/out
COPY --from=builder /data/data/com.termux/files/home/neovim/build/bin/nvim /data/data/com.termux/files/home/out/nvim
COPY --from=builder /data/data/com.termux/files/home/neovim/runtime /data/data/com.termux/files/home/out/runtime
RUN file /data/data/com.termux/files/home/out/nvim > /data/data/com.termux/files/home/out/file-info.txt && \
    { ldd /data/data/com.termux/files/home/out/nvim 2>&1 || true; } > /data/data/com.termux/files/home/out/ldd.txt

# ---- export ----
FROM scratch
COPY --from=runtime /data/data/com.termux/files/home/out /out
CMD ["/out/nvim"]
