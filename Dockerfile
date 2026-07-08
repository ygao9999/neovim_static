FROM termux/termux-docker:latest AS builder

USER 1000:1000

# 安装构建依赖，保留动态 iconv 供 git/make 等使用
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
    # patchelf 用于后期清理动态条目
    patchelf \
    binutils

ARG NVIM_REF=stable
RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim.git /data/data/com.termux/files/home/neovim

WORKDIR /data/data/com.termux/files/home/neovim

ENV CMAKE_BUILD_PARALLEL_LEVEL=2
ENV VERBOSE=1

# ====== 关键：强制最终链接器在链接 nvim 时将 iconv 静态链接 ======
# 方法：通过 CMAKE_EXE_LINKER_FLAGS 在链接命令行末尾追加静态链接指令
# 注意：不能用于 deps 构建，否则影响依赖库的编译（它们需要动态 iconv）
# =================================================================
# Stage 1: deps（不加链接器标志，使用系统默认）
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

# Stage 2: nvim（加入链接器标志强制 iconv 静态）
RUN set -e; \
    for attempt in 1 2 3; do \
      echo "===== nvim build attempt $attempt/3 ====="; \
      if make CMAKE_BUILD_TYPE=Release \
              CMAKE_EXTRA_FLAGS="-DCMAKE_VERBOSE_MAKEFILE=ON \
                -DCMAKE_EXE_LINKER_FLAGS='-Wl,-Bstatic -liconv -Wl,-Bdynamic'" \
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

# ====== 后处理：使用 patchelf 删除残留的动态 libiconv NEEDED ======
# 某些情况下即使静态链接成功，动态条目仍会残留（但二进制内已有完整实现）
# patchelf 可安全移除它，不影响功能。
RUN set -e; \
    echo "=== Checking if iconv symbols are defined ==="; \
    if nm -C build/bin/nvim | grep -q 'libiconv_open'; then \
        echo "iconv symbols found (statically linked)"; \
        echo "=== Removing NEEDED libiconv.so ==="; \
        patchelf --remove-needed libiconv.so build/bin/nvim; \
        echo "=== New dynamic section ==="; \
        readelf -d build/bin/nvim | grep NEEDED; \
    else \
        echo "::warning:: iconv symbols NOT found, cannot remove NEEDED safely"; \
        echo "Keeping original binary (with libiconv.so dependency)"; \
    fi

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
