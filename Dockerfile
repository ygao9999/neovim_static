FROM termux/termux-docker:latest AS builder

USER 1000:1000

# 安装构建依赖（系统提供动态 iconv 供 git 等使用）
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
    # 注意：我们不安装 libiconv-static，因为我们要自己编译


# 自己编译一份纯静态 libiconv（安装到 ~/local）
RUN mkdir -p /data/data/com.termux/files/home/tmp/iconv-build && cd /data/data/com.termux/files/home/tmp/iconv-build && \
    curl -L https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.17.tar.gz -o libiconv.tar.gz && \
    tar xzf libiconv.tar.gz --strip-components=1 && \
    ./configure --prefix=/data/data/com.termux/files/home/local \
                --enable-static \
                --disable-shared \
                --disable-nls \
                --disable-rpath && \
    make -j"$(nproc)" && make install

ARG NVIM_REF=stable
RUN git clone --depth 1 --branch "${NVIM_REF}" https://github.com/neovim/neovim.git /data/data/com.termux/files/home/neovim

WORKDIR /data/data/com.termux/files/home/neovim

ENV CMAKE_BUILD_PARALLEL_LEVEL=2
ENV VERBOSE=1

# 设置环境变量，引导 CMake 找到我们自己的静态 iconv

ENV Iconv_LIBRARY=/data/data/com.termux/files/home/local/lib/libiconv.a
ENV Iconv_INCLUDE_DIR=/data/data/com.termux/files/home/local/include

# deps 构建（不需要 iconv，但设置了变量也没关系）
RUN set -e; \
    for attempt in 1 2 3; do \
      echo "===== deps build attempt $attempt/3 ====="; \
      if make CMAKE_BUILD_TYPE=Release \
              CMAKE_EXTRA_FLAGS="-DCMAKE_VERBOSE_MAKEFILE=ON \
                -DIconv_LIBRARY=${Iconv_LIBRARY} \
                -DIconv_INCLUDE_DIR=${Iconv_INCLUDE_DIR}" \
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

# nvim 构建（强制链接我们自己的静态 iconv）
RUN set -e; \
    for attempt in 1 2 3; do \
      echo "===== nvim build attempt $attempt/3 ====="; \
      if make CMAKE_BUILD_TYPE=Release \
              CMAKE_EXTRA_FLAGS="-DCMAKE_VERBOSE_MAKEFILE=ON \
                -DIconv_LIBRARY=${Iconv_LIBRARY} \
                -DIconv_INCLUDE_DIR=${Iconv_INCLUDE_DIR}" \
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

# ---- 运行时打包阶段 -------------------------------------------------
FROM termux/termux-docker:latest AS runtime
USER 1000:1000
RUN termux-change-repo || true
RUN pkg update && pkg install -y tar file
RUN mkdir -p /data/data/com.termux/files/home/out
COPY --from=builder /data/data/com.termux/files/home/neovim/build/bin/nvim /data/data/com.termux/files/home/out/nvim
COPY --from=builder /data/data/com.termux/files/home/neovim/runtime /data/data/com.termux/files/home/out/runtime
RUN file /data/data/com.termux/files/home/out/nvim > /data/data/com.termux/files/home/out/file-info.txt && \
    { ldd /data/data/com.termux/files/home/out/nvim 2>&1 || true; } > /data/data/com.termux/files/home/out/ldd.txt

# ---- 最终导出 -------------------------------------------------
FROM scratch
COPY --from=runtime /data/data/com.termux/files/home/out /out
CMD ["/out/nvim"]
