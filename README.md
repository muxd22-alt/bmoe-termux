# bmoe-termux

Native build of the [BigMoeOnEdge](https://github.com/Helldez/BigMoeOnEdge)
engine on a phone, in Termux, without proot and without a container.

Termux's own clang builds the engine and its llama.cpp submodule right here,
for this phone's CPU.

## Build

```bash
bash build.sh
```

or through the control command:

```bash
ai build
```

## What it does

1. checks the toolchain (`cmake make clang git`),
2. clones the upstream into `upstream/` (shallow, with the llama.cpp submodule),
3. tunes the CPU flags for the phone and falls back to the portable baseline
   when the silicon refuses them,
4. configures with `BMOE_BUILD_TESTS=OFF` and one CPU library (not one per
   instruction-set tier - on a phone that is an hour of compile for a few
   percent of decode),
5. compiles into `~/ai/build`, where `bin/bmoe-server` and `bin/bmoe-cli` land.

## Environment

| variable | default | meaning |
|---|---|---|
| `BUILD_JOBS` | from free memory (2 on a busy phone) | parallel compile jobs |
| `BMOE_UPSTREAM` | `<repo>/upstream` | where the source lives |
| `BMOE_BUILD_DIR` | `~/ai/build` | the build tree |
| `BMOE_PINNED_COMMIT` | - | pin an upstream commit |

## Notes for a phone

- keep the phone plugged in: a full build is long and the battery will not
  last it otherwise,
- `termux-wake-lock` before a long build,
- the compile is memory hungry; two jobs fit a 12 GB phone that also runs
  other services, four does not.
