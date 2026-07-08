# nvim-static-build

Compile a **fully static** Neovim binary on GitHub Actions using a multi-stage
Alpine (musl) Docker build, then publish it as a workflow artifact and
(optional) GitHub Release.

## Why Alpine / musl?

Standard glibc does not reliably support static linking. Alpine Linux is built
on `musl-libc`, which produces binaries with zero shared-library dependencies —
drop the resulting `nvim` on any Linux x86_64 host (including distroless
containers) and it will run.

## Repo layout

```
.
├── Dockerfile                              # Multi-stage Alpine build
└── .github/workflows/build-nvim-static.yml # CI workflow
```

## How the build works

1. **Builder stage** (`alpine:latest`) installs build tools and the `-static`
   variants of every library Neovim depends on (libuv, libvterm, libtermkey,
   tree-sitter, ncurses, unibilium, gettext, …), then clones Neovim at the
   requested ref and runs `make CMAKE_BUILD_TYPE=Release CMAKE_EXTRA_FLAGS="-DSTATIC_BUILD=1"`.
2. **Runtime stage** copies the compiled `nvim` binary **and** the `runtime/`
   directory (syntax files, Lua stdlib, autoload scripts) so the binary is
   usable on hosts without Neovim installed.
3. **Export stage** (`scratch`) holds just `/out/nvim` and `/out/runtime`,
   which the workflow extracts with `docker create` + `docker cp`.

## Workflow features

| Feature | How |
|---|---|
| Trigger on push / PR / manual / weekly | `on:` block at the top of the workflow |
| Pick any Neovim tag/branch/commit | `workflow_dispatch` input `nvim_ref`, defaults to `stable` |
| Fast rebuilds | `docker/setup-buildx-action` + GHA cache (`cache-from/cache-to: type=gha`) |
| Static-link verification | `ldd ./nvim` must report no shared deps, else the job fails |
| Headless smoke test | Runs `nvim --version` and a `lua print(...)` eval with bundled runtime |
| Artifact upload | `actions/upload-artifact@v4` (30-day retention) |
| GitHub Release | Optional, only when `publish_release` is checked on manual dispatch |
| Cancel superseded runs | `concurrency` group keyed on the git ref |

## Local usage (without GitHub Actions)

```bash
# 1. Build
docker build -t nvim-static --build-arg NVIM_REF=v0.10.4 .

# 2. Extract
id=$(docker create nvim-static)
mkdir -p out && docker cp "$id:/out/." out/ && docker rm "$id" > /dev/null

# 3. Run
export VIMRUNTIME="$PWD/out/runtime"
./out/nvim --version
```

## Consuming the CI artifact

After a successful CI run, download the `nvim-static-stable` artifact, extract
it, and either:

```bash
# Easy way — launcher sets VIMRUNTIME for you
./nvim.sh

# Or manually
export VIMRUNTIME=/path/to/runtime
./nvim
```

## Verifying static linkage

```bash
ldd ./nvim
# expected: not a dynamic executable
```

## Multi-arch support (x86_64 + ARM64)

The workflow uses a **matrix strategy** to build both architectures in parallel:

| Arch | Runner | Platform | Notes |
|---|---|---|---|
| `x86_64` | `ubuntu-latest` | `linux/amd64` | Native build |
| `arm64` | `ubuntu-24.04-arm` | `linux/arm64` | Native ARM runner (fastest) |

Both jobs run concurrently — ARM64 does **not** block x86_64. `fail-fast: false`
means one arch failing does not cancel the other.

### Picking arches on manual dispatch

The `workflow_dispatch` form exposes an `arches` input. Default is
`x86_64,arm64` (both). Type any subset, e.g. just `arm64`, to build only that
architecture.

### Fallback: QEMU emulation (when native ARM runner is unavailable)

GitHub-hosted ARM runners (`ubuntu-24.04-arm`) require a paid plan for private
repos. If you can't use them, switch to QEMU emulation on a standard x86_64
runner — much slower but works anywhere:

```yaml
matrix:
  include:
    - arch: x86_64
      runner: ubuntu-latest
      platform: linux/amd64
      need_qemu: false
    - arch: arm64
      runner: ubuntu-latest           # ← changed
      platform: linux/arm64
      need_qemu: true                 # ← enables docker/setup-qemu-action
```

The `Set up QEMU` step is gated on `matrix.need_qemu`, so it only runs when
needed and adds zero overhead to native builds.

### Why this works without Dockerfile changes

Alpine publishes native `aarch64` images and `apk` automatically resolves the
correct arch. The same `Dockerfile` builds both x86_64 and ARM64 binaries — no
per-arch patches needed.

### Artifacts per arch

Each arch produces its own workflow artifact:
- `nvim-static-stable-x86_64` (contains `nvim-static-stable-x86_64.tar.gz` + `.zip`)
- `nvim-static-stable-arm64`   (contains `nvim-static-stable-arm64.tar.gz` + `.zip`)

When `publish_release` is checked, the `release` job downloads **all** arch
artifacts, merges their `SHA256SUMS-*.txt` into one `SHA256SUMS.txt`, verifies
the checksums, and attaches everything to a single GitHub Release.

## Caveats

- The binary is **Linux only** (no macOS / Windows static builds — those need
  completely different toolchains).
- ARM64 binaries built via QEMU take ~3–4x longer than native. Prefer the
  native ARM runner when available.
- The runtime directory is required — without it, syntax highlighting, built-in
  Lua stdlib, and many `:help` features will be missing.
- `tree-sitter parsers` are **not** bundled; install them via `:TSInstall`
  (nvim-treesitter plugin) on the target host if you need parser support.
