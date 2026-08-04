# verif_riscv_dv_batch.py

Batch driver that runs [riscv-dv](https://github.com/chipsalliance/riscv-dv)
(originally `google/riscv-dv`) random-instruction generation against the
Zeppelin RTL, escalating instruction count over many iterations and emailing
a report when something fails.

## 1. Setting up riscv-dv

riscv-dv is an external tool, not vendored into this repo. It generates
randomized RISC-V assembly programs, which get compiled and run against the
Zeppelin RTL simulation and (optionally) an ISS (spike) for trace comparison.

### 1.1 Clone it

By default the script looks for a clone at `~/riscv-dv`:

```bash
git clone https://github.com/chipsalliance/riscv-dv.git ~/riscv-dv
```

To use a clone somewhere else, pass `--riscv_dv_path PATH` to any step that
invokes riscv-dv (`--compile_riscv_dv`, `--gen_asm`, `--batch`). The path is
validated (checked for `run.py`) before riscv-dv is invoked; if it's missing
or doesn't look like a riscv-dv checkout, the script exits immediately with
an error telling you what path it looked for and how to fix it, rather than
failing later with an opaque subprocess error.

### 1.2 Install its Python dependencies

```bash
cd ~/riscv-dv
pip3 install -r requirements.txt
```

(`PyYAML`, `bitstring`, `pyvsc`, `tabulate`, `pandas`, plus doc-build tools
riscv-dv doesn't strictly need at runtime.)

### 1.3 Set the environment variables riscv-dv expects

riscv-dv's `run.py` needs a RISC-V GCC toolchain and, for trace comparison,
an ISS. It reads these from environment variables:

| Variable | Points to |
|---|---|
| `RISCV_GCC` | `<toolchain>/bin/riscv64-unknown-elf-gcc` |
| `RISCV_OBJCOPY` | `<toolchain>/bin/riscv64-unknown-elf-objcopy` |
| `SPIKE_PATH` | directory containing the `spike` binary |

### 1.4 Simulator and other fixed riscv-dv flags

Every riscv-dv invocation (`RISCV_DV_CMD` in the script) uses the same base
flags, none of which are configurable via CLI:

| Flag | Value | Meaning |
|---|---|---|
| `--simulator` | `vcs` | VCS must be on `PATH` and licensed. No spike-only or other-simulator mode. |
| `--mabi` | `ilp32` | RV32 ABI. |
| `--isa` | `rv32im_zicsr_zifencei` | Fixed instruction-set string passed to the generator. |
| `--iss_timeout` | `300` | riscv-dv's own internal ISS (spike) comparison timeout, in seconds — distinct from the 300s wall-clock timeout the script itself applies to each simulation run in `--run_tests` (§3). |
| `--verbose` | (always on) | riscv-dv prints its own verbose log lines on every invocation; there's no flag to quiet it. |

Per-call flags (`-o`, `--custom_target`, `--co`/`--so`/`--steps=all`,
`--seed`) are appended on top of these at each call site.

## 2. What the script touches

All paths are resolved relative to the repo root (`REPO_ROOT`, two levels up
from this script), regardless of your cwd:

| Path | Purpose |
|---|---|
| `tools/verif_elf_suites.yaml` | Suite definitions (harness + parameter overrides) consumed by `step_gen_elf` |
| `hw/top/test/riscv_dv_asm/elf_suites/` | Generated per-suite `.v` test harness wrappers + `riscv_dv_elf_suites.cmake` manifest |
| `hw/top/test/riscv_dv_asm/custom_targets/` | riscv-dv "custom target" configs (one subdir per target — currently only `rv32_*_blimp` targets exist; the script discovers targets by listing subdirectories, it does not hard-code target names) |
| `hw/top/test/riscv_dv_asm/gen_asm/<target>/` | Raw riscv-dv output per target (compiled generator + generated `.S`) |
| `hw/top/test/riscv_dv_asm/test_asm/` | Generated `.S` files rewritten into Zeppelin's test-harness entry/exit convention |
| `hw/top/test/riscv_dv_asm/logs/<batch-timestamp>/` | One `.log` report per batch iteration |
| `build_RISCV_DV_BATCH_SCRIPT_DESIGNATED___/` (or `--build_dir`) | CMake build directory (repo root by default) — holds the ELF suite binaries and compiled ASM tests |

`elf_suites/`, `gen_asm/`, `test_asm/`, and `logs/` are all generated output
and are listed in `.gitignore`.

Two things to watch for:

- **`logs/` is never cleaned up automatically.** `--clean` and each batch
  iteration's end-of-loop cleanup (`step_batch` step 6) only touch
  `elf_suites/`, `gen_asm/`, `test_asm/`, and the build dir — every
  `--batch` run adds a new `logs/<timestamp>/` directory that stays forever.
  Prune old ones by hand if disk usage matters.
- **A custom `--build_dir` is only gitignored if its name matches
  `build*/`.** The repo-root `.gitignore` ignores `build*/` generically,
  which covers the default `build_RISCV_DV_BATCH_SCRIPT_DESIGNATED___`, but
  if you point `--build_dir` at a directory with a different name (or
  outside the repo entirely) you're responsible for keeping it out of git
  yourself.

## 3. Usage

Run from anywhere; paths are absolute internally.

```bash
python tools/verif_riscv_dv_batch.py <flags>
```

### All flags

Every flag the script accepts. See the following subsections for what each
mode-selecting flag (`--clean`, `--gen_elf`, etc.) actually does; this table
is the complete reference, including flags not called out elsewhere.

| Flag | Default | Applies to | Meaning |
|---|---|---|---|
| `--clean` | off | standalone | See "Individual steps" below. |
| `--gen_elf` | off | standalone | See "Individual steps" below. |
| `--instr_cnt N` | none | standalone | See "Individual steps" below. |
| `--compile_riscv_dv` | off | standalone | See "Individual steps" below. |
| `--gen_asm` | off | standalone | See "Individual steps" below. |
| `--seed SEED` | auto (wall-clock derived) | `--gen_asm` only | Fixes the riscv-dv seed for a standalone `--gen_asm` call, so you can reproduce a specific generated program. **Has no effect on `--batch`** — the batch loop always derives a fresh seed from wall-clock time each iteration (the seed used is printed and written into each iteration's report/log, but there's no flag to force a specific seed in `--batch`). |
| `--transform_asm` | off | standalone | See "Individual steps" below. |
| `--config_build` | off | standalone | See "Individual steps" below. |
| `--run_tests` | off | standalone | See "Individual steps" below. |
| `--batch` | off | mode select | Runs the full setup + loop flow; see "Full batch flow" below. |
| `--no_setup` | off | `--batch` only | Skip the one-time setup phase and jump into the loop. |
| `--stop_on_failure` | off | `--batch` only | Stop the loop after the first iteration with any failing test. |
| `--bound N` | `300` | `--batch` only | Run for N iterations then stop. Mutually exclusive with `--unbound`. |
| `--unbound` | off | `--batch` only | Run forever (Ctrl-C to stop). Mutually exclusive with `--bound`. |
| `--parallel N` | `1` | `--config_build`, `--run_tests`, `--batch` | Concurrent `make -j` workers and concurrent test-run threads (§ "Multi-core / `--parallel`" below). Ignored by every other step. **Be careful when running multi-core on large workloads.** Use the `htop` command to learn about and monitor the health of the server. |
| `--riscv_dv_path PATH` | `~/riscv-dv` | `--compile_riscv_dv`, `--gen_asm`, `--batch` | Path to the riscv-dv clone; `~` and relative paths are expanded/resolved to an absolute path before use. Validated (checked for `run.py`) before riscv-dv is invoked. |
| `--build_dir PATH` | `<repo_root>/build_RISCV_DV_BATCH_SCRIPT_DESIGNATED___` | `--clean`, `--config_build`, `--run_tests`, `--batch` | CMake build directory; `~` and relative paths are expanded/resolved to an absolute path before use. |
| `--email ADDRESS` | none (no email sent) | `--batch` only | See §3.1. Ignored by every other step — there's no equivalent for a single `--run_tests` invocation. |

Note: nothing enforces that you pass exactly one of the standalone/`--batch`
mode flags — e.g. `--clean --gen_elf` runs `--clean` and exits before
`--gen_elf` is ever checked, because `main()` checks and exits on each flag
in a fixed if/elif-style order (see the source for the exact precedence). If
no mode flag is given at all, the script just prints a usage hint and exits
0 without doing anything.

### Individual steps (each runs once and exits)

| Flag | What it does |
|---|---|
| `--clean` | Empties `elf_suites/`, `test_asm/`, `gen_asm/`, and the build dir, then removes the (now-empty) build dir. Run this before `--config_build` if the build dir already exists. |
| `--gen_elf` | Reads `verif_elf_suites.yaml`, writes one `<version>_elf_test_suite_<N>.v` per suite into `elf_suites/`, plus the cmake manifest listing them all. Skips files whose content is already up to date. |
| `--instr_cnt N` (N ≥ 10) | Rewrites the active (uncommented) `+instr_cnt=N` line in every `custom_targets/*/testlist.yaml`. |
| `--compile_riscv_dv` | Runs `run.py --co` once per custom target inside the riscv-dv clone, compiling the SV instruction generator into `gen_asm/<target>/`. Lets later `--gen_asm` calls skip recompilation via `--so`. |
| `--gen_asm [--seed N]` | Runs `run.py --so` (or `--steps=all` if not pre-compiled) once per custom target, writing generated assembly under `gen_asm/<target>/asm_test/`. Without `--seed`, one is derived from wall-clock time and printed. |
| `--transform_asm` | Converts every `gen_asm/<target>/asm_test/*.S` into a Zeppelin-compatible test: slices from the `init:` label to (not including) `kernel_instr_start:`, renames `init:` → `test_entry:`, and replaces the riscv-dv `test_done`/`write_tohost` exit sequence with a jump to `test_return`. Writes to `test_asm/`. Files missing the expected labels are skipped with a warning, not fatal. |
| `--config_build` | Creates the build dir (errors out if it already exists — run `--clean` first) and configures it with `cmake .. -DCOVERAGE=1 -DTRACE=1`. Then builds all ELF suite binaries (`make -k -j<parallel> riscv-dv-elf-tests`) from whatever `.v` files are currently in `elf_suites/`. |
| `--run_tests` | Builds `asm-test-<name>` for every `.S` in `test_asm/`, then runs every (suite binary × asm test) pair in parallel (300s timeout each), printing PASS/FAIL inline. Exits 0 only if every pair passed. |

`--config_build` and the ASM-build phase of `--run_tests` both invoke `make
-k` (keep going past the first failed target) and never check its exit
code directly — a build failure is only detected indirectly, afterward, by
checking whether the expected output binary exists. If `make` fails for a
reason that still leaves a stale binary in place (rare, but possible with a
partial/incremental build), that failure could go unnoticed.

### Multi-core / `--parallel`

`--parallel N` (default `1`, i.e. fully serial) is the one concurrency knob
in the script, used in three places:

1. `--config_build`: `make -j<parallel> riscv-dv-elf-tests` (building ELF
   suite binaries).
2. `--run_tests` phase 1: `make -j<parallel> asm-tests` (building the
   transformed ASM test binaries).
3. `--run_tests` phase 2: a `ThreadPoolExecutor(max_workers=parallel)`
   running every `(suite × asm)` pair concurrently — each pair is its own
   `subprocess.run` (a real separate VCS process), so this is genuine
   process-level parallelism, not just threads contending over the GIL.

`--batch` forwards its own `--parallel` value into both `--config_build` and
`--run_tests` every iteration. There's no separate knob for build-time vs.
run-time parallelism, and no auto-detection of core count — you always get
exactly what you pass (or 1, serially, if you pass nothing).

### Global options (apply to any step above)

| Flag | Default | Meaning |
|---|---|---|
| `--riscv_dv_path PATH` | `~/riscv-dv` | Path to the riscv-dv clone. Checked (for `run.py`) before any step that shells out to it (`--compile_riscv_dv`, `--gen_asm`, `--batch`); exits with an error if not found. `~` and relative paths are resolved to an absolute path before use. |
| `--build_dir PATH` | `<repo_root>/build_RISCV_DV_BATCH_SCRIPT_DESIGNATED___` | CMake build directory used by `--clean`, `--config_build`, `--run_tests`, `--batch`. `~` and relative paths are resolved to an absolute path before use. |

### Full batch flow

```bash
python tools/verif_riscv_dv_batch.py --batch [--bound N | --unbound] \
    [--no_setup] [--stop_on_failure] [--parallel N] \
    [--riscv_dv_path PATH] [--build_dir PATH] [--email ADDRESS]
```

**Setup phase** (once, skipped with `--no_setup`): `--clean` →
`--gen_elf` → `--config_build` → `--compile_riscv_dv`.

**Loop** (one iteration = one `instr_cnt` value), until `--bound` iterations
(default 300) or forever with `--unbound`. `instr_cnt` always **starts at
10** — this is hardcoded in `step_batch`, not configurable via CLI. A
standalone `--instr_cnt N` call before `--batch` has no lasting effect: the
loop's first iteration immediately overwrites every `testlist.yaml` back to
`+instr_cnt=10` regardless of what it was set to beforehand (`--no_setup`
doesn't change this — it only skips `--clean`/`--gen_elf`/`--config_build`/
`--compile_riscv_dv`, not the loop's own `step_set_instr_cnt(10)` call):

1. Set `+instr_cnt=<current>` in every `testlist.yaml`.
2. Generate new random assembly (`--gen_asm`, `--so`, fresh seed each
   iteration — `--seed` has no effect here, see "All flags" above).
3. Transform it into Zeppelin's convention.
4. Build and run every (suite × asm test) pair; write a report to
   `logs/<batch-start-timestamp>/iter_NNNN_<timestamp>.log`. The report only
   records PASS/FAIL/SKIP/BUILD_ERR status per pair — each run's captured
   stdout/stderr is held in memory (`TestResult.stdout`/`.stderr`) but never
   written anywhere, so a FAIL in the log has no accompanying simulation
   output to inspect; you'd need to reproduce it manually via `--run_tests`
   or by running the suite binary directly.
5. If any test failed: email a failures-only report (see §3.1) and, with
   `--stop_on_failure`, stop the loop.
6. Clean `test_asm/` and `build.../riscv_dv_asm/` (but *not* the rest of the
   build dir, so the ELF suite binaries aren't rebuilt every iteration).
7. Advance `instr_cnt` (see "Instruction count escalation" below for detail).

Ctrl-C at any point ends the loop cleanly (prints how many iterations
completed); it does not roll back the current iteration's files.

### Instruction count escalation

Each batch iteration runs with a longer generated program than the last, on
the theory that short programs are cheap to run and catch simple bugs fast,
while some bugs (state that only accumulates over many instructions, rare
generator sequences, etc.) only show up in longer runs. `instr_cnt` starts
at 10 and advances through three phases (`step_batch` in the script):

| Phase | `instr_cnt` range | Step | Rationale |
|---|---|---|---|
| 1 | `10`–`99` | +10 every **15 iterations** at the same count | Spend more iterations per count while programs are cheap, to get many random seeds' worth of coverage at each small size before growing it. |
| 2 | `100`–`999` | +10 every iteration | Once each run costs enough to be worth doing once, stop repeating a count and just climb steadily. |
| 3 | `≥ 1000` | doubling step (current increment ×1.2 each time, increment itself starts at 100) | Linear +10 steps would take forever to reach large counts, so growth accelerates — each iteration's increment is 20% bigger than the last. |

Phase 3 saturates at **`instr_cnt = 100,000`** — once reached, every
subsequent iteration runs at exactly 100,000 instructions rather than
continuing to grow. (This was previously capped at 1,000,000; lowered to
keep the largest per-iteration runs — and their wall-clock cost — bounded to
something more practical.)

With the default `--bound 300`, the loop reliably reaches the 100,000 cap
well before the bound is hit: phase 1 (`10`–`90`) takes 135 iterations,
phase 2 (`100`–`990`) takes another 90 (reaching `instr_cnt=1000` at
iteration 226), and phase 3's ×1.2 doubling growth reaches the 100,000 cap
by iteration 256 — the last 44 of the default 300 iterations all run at the
full 100,000-instruction cap.

### 3.1 Email reports

By default **no email is ever sent**. Passing `--email ADDRESS` to `--batch`
opts in: on any batch iteration with a failure, a plain-text report
(failing/skipped rows only) is emailed via `smtplib` to that address. No
email is sent for all-pass iterations, and none is sent at all if `--email`
is omitted. Every iteration's full report (pass and fail) is written to disk
under `logs/` regardless of `--email`.

Email delivery itself still assumes a local mail relay is listening — see §4.

## 4. Current Limitations

- **`make -k` failures are only caught indirectly** — `step_config_build`
  and `step_run_tests`'s ASM-build phase don't check `make`'s exit code;
  they infer success purely from whether the expected output binary exists
  afterward (see the note under "Individual steps" in §3).
- **Captured stdout/stderr from failing test runs is discarded** — see the
  note under "Full batch flow" step 4 in §3. Only PASS/FAIL/SKIP/BUILD_ERR
  status makes it into the log/report/email; there's currently no way to
  see *why* a run failed without reproducing it separately.
