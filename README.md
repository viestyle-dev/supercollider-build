# SuperCollider builds for Debian-based ARM Linux

Automated builds of [SuperCollider](https://github.com/supercollider/supercollider) for
**any Debian-based Linux system** running on 32-bit (`armv7`) or 64-bit (`arm64`) ARM
hardware — Raspberry Pi OS, Armbian, DietPi, plain Debian, and similar derivatives. Nothing
in the build is board-specific; it was originally built with the Raspberry Pi Zero 2 W in
mind, but the resulting binaries work on any device running a compatible Debian-family OS
on the same architecture. Builds run on GitHub Actions and are published as GitHub Releases.

## What gets built

Each build compiles `scsynth` headless — the Qt IDE (`SC_QT`) and the Emacs/Vim/other
editor integrations (`SC_EL`, `SC_VIM`, `SC_ED`) are disabled, since these binaries are
meant to run as a headless audio server, not a desktop IDE. `-DNATIVE=OFF` is used so the
resulting binaries are portable across ARM cores in general rather than tuned to whichever
CPU happened to compile them.

## Files

| File | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build for **armv7** (32-bit). Cross-built via QEMU emulation on a standard x86_64 runner. |
| `Dockerfile.arm64` | Multi-stage build for **arm64** (64-bit). Built natively on GitHub's arm64-hosted runner — no emulation needed. |
| `.github/workflows/build-supercollider.yml` | Resolves the SuperCollider version to build, runs both architecture builds in parallel, and publishes a single GitHub Release with both tarballs attached. |

Both Dockerfiles share the same stage layout:

1. **`builder`** — Debian bullseye image with the SuperCollider build dependencies; clones the
   requested tag and compiles it with CMake.
2. **`artifact`** — a `scratch`-based stage containing only `/opt/supercollider`, used to export
   the compiled binaries as a plain directory (`docker buildx build --target artifact -o type=local,dest=...`).
3. **`runtime`** — a slim Debian image with just the runtime shared libraries, for anyone who
   wants to run `scsynth` directly in Docker instead of extracting the tarball onto a device.

Both stages build against Debian bullseye so the armv7 and arm64 binaries link against the
same library versions that ship with Debian-based distros (Raspberry Pi OS, Armbian, DietPi,
plain Debian, etc.), avoiding glibc/ABI mismatches that can happen when building on an
unrelated distro family (e.g. Alpine/musl, or Ubuntu's differently-versioned packages).

## Triggering a build

The workflow runs:

- **Automatically** every Monday at 03:00 UTC, building the latest SuperCollider release if
  one hasn't been built yet.
- **Manually** via the Actions tab → "Build SuperCollider" → "Run workflow". Leave the
  `sc_version` input blank to build the latest release, or provide a specific tag
  (e.g. `Version-3.14.1`) to build that version instead.

If a release for the resolved version already exists, the workflow skips the build entirely.

## Deploying to a device

Builds are published under the repository's **Releases** page, tagged `sc-<version>`
(e.g. `sc-Version-3.14.1`), each with two assets:

- `supercollider-<version>-armv7.tar.gz` — for 32-bit Debian-based OSes (armhf/armv7l)
- `supercollider-<version>-arm64.tar.gz` — for 64-bit Debian-based OSes (aarch64/arm64)

These steps apply to any Debian-family device — a Raspberry Pi, an Armbian/DietPi board, or
a plain Debian ARM machine — not just the Pi Zero 2 W this project started with.

### 1. Check which architecture the device is running

```bash
uname -m
# armv7l -> use the armv7 tarball
# aarch64 -> use the arm64 tarball
```

### 2. Get the tarball onto the device

Either download it directly on the device:

```bash
# with the GitHub CLI (gh auth login once beforehand)
gh release download sc-<version> \
  --repo viestyle-dev/supercollider-build \
  --pattern 'supercollider-<version>-<arch>.tar.gz'

# or with curl, no gh required
curl -LO https://github.com/viestyle-dev/supercollider-build/releases/download/sc-<version>/supercollider-<version>-<arch>.tar.gz
```

...or build/download it on your Mac first and `scp` it over (replace `pi@raspberrypi.local`
with the device's own user/hostname):

```bash
scp supercollider-<version>-<arch>.tar.gz pi@raspberrypi.local:~/
```

### 3. Install runtime dependencies

The tarball only contains SuperCollider itself; the shared libraries it links against still
need to come from `apt` (same list as the Dockerfiles' `runtime` stage):

```bash
sudo apt-get update
sudo apt-get install -y libsndfile1 libasound2 libavahi-client3 libfftw3-single3 \
  libjack-jackd2-0 jackd2
```

### 4. Extract and run

```bash
sudo tar xzf supercollider-<version>-<arch>.tar.gz -C /opt
echo 'export PATH="/opt/supercollider/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

scsynth -u 57110
```

If `jackd` is the audio backend, start it first (or let `qjackctl`/`patchbox` manage it);
`scsynth` will otherwise fall back to ALSA if built/run accordingly.

### 5. (Optional) Run scsynth as a systemd service

To have `scsynth` start automatically on boot:

```bash
sudo tee /etc/systemd/system/scsynth.service > /dev/null <<'EOF'
[Unit]
Description=SuperCollider audio server
After=sound.target network.target

[Service]
ExecStart=/opt/supercollider/bin/scsynth -u 57110
Restart=on-failure
User=pi  # replace with your actual login user if not on Raspberry Pi OS

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now scsynth
sudo systemctl status scsynth
```

### Upgrading

To move to a newer build, repeat steps 2 and 4 — extracting overwrites `/opt/supercollider`
in place. Restart the service (`sudo systemctl restart scsynth`) if you're running it under
systemd.

## Building locally on macOS

Both files build with plain `docker buildx build` under Docker Desktop for Mac — no extra
setup is required on Intel Macs. On Apple Silicon (M1/M2/M3/M4), `arm64` is the host's native
architecture, but Apple's CPUs do **not** support 32-bit ARM execution, so `armv7` still needs
QEMU emulation there too.

If a build fails with `exec format error` or buildx can't find the platform, register the QEMU
emulators once:

```bash
docker run --privileged --rm tonistiigi/binfmt --install all
```

Each Dockerfile has three export targets, all producing plain files/directories via
`-o type=local,dest=...` (no `docker images` entry, no `--load` needed):

- `artifact` — the raw `/opt/supercollider` directory, unpacked.
- `release` — just the packaged `supercollider-<version>-<arch>.tar.gz`, built **inside**
  Docker (the packaging step runs on the build host's native platform via `$BUILDPLATFORM`,
  so it doesn't pay the QEMU tax just to run `tar`).

The `runtime` stage (the default, unnamed target) is the one meant for `-t`/`--load` if you
want an image that runs `scsynth` directly.

### `Dockerfile` (armv7 / 32-bit)

Always emulated via QEMU on macOS, regardless of chip (Intel or Apple Silicon):

```bash
# Get supercollider-<version>-armv7.tar.gz packaged by Docker
docker buildx build --platform linux/arm/v7 -f Dockerfile \
  --target release -o type=local,dest=./dist-armv7 .

# Or build the runtime image (scsynth) and load it into `docker images`
docker buildx build --platform linux/arm/v7 -f Dockerfile -t supercollider:armv7 --load .
docker run --rm supercollider:armv7 -v   # quick smoke test (emulated, so slower than native)
```

### `Dockerfile.arm64` (arm64 / 64-bit)

Native (no emulation) on Apple Silicon Macs; still QEMU-emulated on Intel Macs:

```bash
# Get supercollider-<version>-arm64.tar.gz packaged by Docker
docker buildx build --platform linux/arm64 -f Dockerfile.arm64 \
  --target release -o type=local,dest=./dist-arm64 .

# Or build the runtime image (scsynth) and load it into `docker images`
docker buildx build --platform linux/arm64 -f Dockerfile.arm64 -t supercollider:arm64 --load .
docker run --rm supercollider:arm64 -v   # quick smoke test
```

Pass `--build-arg SC_VERSION=Version-x.y.z` to any of the commands above to pin a specific
SuperCollider tag instead of the Dockerfile's default.
