#!/usr/bin/env python3
#=========================================================================
# verif_riscv_dv_batch.py
#=========================================================================
# Batch script for running riscv-dv ELF tests against ZeppelinV8 and Zeppelin.
#
# Usage:
#   python tools/verif_riscv_dv_batch.py --clean
#   python tools/verif_riscv_dv_batch.py --gen_elf

import argparse
import concurrent.futures
import dataclasses
import hashlib
import os
import re
import shutil
import smtplib
import subprocess
import sys
import threading
import yaml
from datetime import datetime
from email.mime.text import MIMEText
from pathlib import Path

#-------------------------------------------------------------------------
# Paths
#-------------------------------------------------------------------------
#
# BUILD_DIR and RISCV_DV_CLONE_PATH default to the values below but are
# overridable via --build_dir / --riscv_dv_path (see main()); the globals
# here are only the defaults used to populate argparse.

REPO_ROOT              = Path(__file__).resolve().parent.parent
VERSIONS_YAML          = Path(__file__).resolve().parent / "verif_elf_suites.yaml"
DEFAULT_BUILD_DIR      = REPO_ROOT / "build_RISCV_DV_BATCH_SCRIPT_DESIGNATED___"
DEFAULT_RISCV_DV_PATH  = Path.home() / "riscv-dv"
ELF_SUITES_DIR         = REPO_ROOT / "hw" / "top" / "test" / "riscv_dv_asm" / "elf_suites"
GEN_ASM_DIR            = REPO_ROOT / "hw" / "top" / "test" / "riscv_dv_asm" / "gen_asm"
TEST_ASM_DIR           = REPO_ROOT / "hw" / "top" / "test" / "riscv_dv_asm" / "test_asm"
CUSTOM_TARGETS_DIR     = REPO_ROOT / "hw" / "top" / "test" / "riscv_dv_asm" / "custom_targets"
LOG_DIR                = REPO_ROOT / "hw" / "top" / "test" / "riscv_dv_asm" / "logs"

#-------------------------------------------------------------------------
# Report / email configuration
#-------------------------------------------------------------------------
#
# No email is ever sent unless --email is passed on the command line; see
# main(). REPORT_EMAIL_FROM/HOST/PORT assume a local mail relay
# (sendmail/postfix) listening on port 25 -- if there isn't one,
# _send_failure_email just prints a warning and continues.

REPORT_EMAIL_FROM = "zeppelin-verif@localhost"
REPORT_SMTP_HOST  = "localhost"
REPORT_SMTP_PORT  = 25

# Set from args in main(); module-level so step_* functions (called from
# both main() and step_batch()) don't need it threaded through every call.
RISCV_DV_CLONE_PATH = DEFAULT_RISCV_DV_PATH
BUILD_DIR           = DEFAULT_BUILD_DIR

# Base flags shared by every riscv-dv invocation.
# Per-call flags (-o, --custom_target, --co/--so/--steps=all, --seed) are
# appended at call sites.
RISCV_DV_CMD        = [
  "python", "run.py",
  "--simulator", "vcs",
  "--verbose",
  "--mabi=ilp32",
  "--isa=rv32im_zicsr_zifencei",
  "--iss_timeout=300",
]

def _load_version_meta():
  """Load processor version metadata and suite definitions from verif_elf_suites.yaml."""
  with VERSIONS_YAML.open() as f:
    data = yaml.safe_load(f)
  meta = {}
  for version, entry in data["versions"].items():
    meta[version] = {
      "harness_include": entry["harness_include"],
      "suites": entry.get("suites", []),
    }
  return meta

_VERSION_META = _load_version_meta()

_CMAKE_FILENAME = "riscv_dv_elf_suites.cmake"

#-------------------------------------------------------------------------
# Result dataclass
#-------------------------------------------------------------------------

@dataclasses.dataclass
class TestResult:
  suite:    str
  asm_name: str
  build_ok: bool        = False  # True only when both suite and ASM builds succeeded
  run_ok:   bool | None = None   # None means skipped (build failed)
  stdout:   str         = ""
  stderr:   str         = ""

  def status_str( self ):
    if not self.build_ok:
      return "BUILD_ERR"
    if self.run_ok is None:
      return "SKIP"
    return "PASS" if self.run_ok else "FAIL"

#-------------------------------------------------------------------------
# Formatting helpers
#-------------------------------------------------------------------------

_WIDTH = 72

def _banner( msg ):
  print(f"\n{'=' * _WIDTH}\n  {msg}\n{'=' * _WIDTH}")

def _check_riscv_dv_clone():
  """
  Verify RISCV_DV_CLONE_PATH points at a riscv-dv checkout (looks for run.py),
  exiting with a clear error otherwise instead of letting subprocess.run fail
  later with an opaque FileNotFoundError/CalledProcessError.
  """
  if not (RISCV_DV_CLONE_PATH / "run.py").exists():
    print(f"Error: no riscv-dv checkout found at {RISCV_DV_CLONE_PATH}\n"
          f"  (expected to find {RISCV_DV_CLONE_PATH / 'run.py'})\n"
          f"  Clone it there, e.g.:\n"
          f"    git clone https://github.com/chipsalliance/riscv-dv.git {RISCV_DV_CLONE_PATH}\n"
          f"  or point --riscv_dv_path at an existing clone.",
          file=sys.stderr)
    sys.exit(1)


def _run( cmd, cwd, capture=False, check=True ):
  """Run a shell command, streaming or capturing output."""
  result = subprocess.run(cmd, cwd=str(cwd), text=True, capture_output=capture)
  if check and result.returncode != 0:
    raise subprocess.CalledProcessError(result.returncode, cmd,
                                        result.stdout, result.stderr)
  return result


#=========================================================================
# .v file generation helpers
#=========================================================================

_V_TEMPLATE = """\
//========================================================================
// {module_name}.v
//========================================================================
// ELF test suite {suite_num}: {comment}
// Auto-generated by tools/verif_riscv_dv_batch.py -- do not edit by hand.

`include "{harness_include}"

module {module_name};
  {version}TestHarness{param_block} h();

  string elf_file;

  initial begin
    test_bench_begin( `__FILE__ );

    h.t.timeout = 100_000_000;
    if ( !$value$plusargs( "elf=%s", elf_file ) )
      $fatal( 0, "No ELF file specified with +elf=/path/to/elf" );

    h.t.test_case_begin( $sformatf( "suite {suite_num}: %s", elf_file ) );
    h.load_elf( elf_file );
    h.check_elf_traces();
    h.t.test_case_end();

    test_bench_end();
  end
endmodule
"""


# Params whose width is p_num_pipes*8 bits (one byte per pipe)
_PER_PIPE_PARAMS    = {"p_sim_d2x_bp", "p_sim_x2w_bp"}
# Params whose width is p_num_fe_lanes*8 bits (one byte per lane)
_PER_FE_LANE_PARAMS = {"p_sim_f2d_bp"}

# Matches a concatenation of 8-bit Verilog literals: {8'd0, 8'd5, ...}
_BYTE_CONCAT_RE = re.compile(r"^\{((?:8'd\d+,\s*)*8'd\d+)\}$")


def _zero_pad_concat( value, target_bytes ):
  """Prepend 8'd0 terms to a {8'd..., ...} concat to reach target_bytes."""
  m = _BYTE_CONCAT_RE.match(str(value).replace(" ", ""))
  if not m:
    return value
  terms = [t.strip() for t in m.group(1).split(",")]
  if len(terms) >= target_bytes:
    return value
  pad = ["8'd0"] * (target_bytes - len(terms))
  return "{" + ", ".join(pad + terms) + "}"


def _format_harness_params( params ):
  """Return a ' #(\\n  .p_x (v)\\n  )' block, or '' when params is empty."""
  if not params:
    return ""

  # Compute expected byte counts for variable-width backpressure params
  num_alus     = int(params.get("p_num_alus",     4))
  num_muls     = int(params.get("p_num_muls",     2))
  num_pipes    = int(params.get("p_num_pipes",    num_alus + num_muls + 2))
  num_fe_lanes = int(params.get("p_num_fe_lanes", 4))

  max_name_len = max(len(name) for name in params)
  lines = []
  for name, value in params.items():
    if name in _PER_PIPE_PARAMS:
      value = _zero_pad_concat(value, num_pipes)
    elif name in _PER_FE_LANE_PARAMS:
      value = _zero_pad_concat(value, num_fe_lanes)
    padding = " " * (max_name_len - len(name))
    lines.append(f"    .{name}{padding} ({value})")
  return " #(\n" + ",\n".join(lines) + "\n  )"


def _generate_v( version, harness_include, suite ):
  module_name = f"{version}_elf_test_suite_{suite['num']}"
  param_block = _format_harness_params(suite.get("params") or {})
  return _V_TEMPLATE.format(
    module_name     = module_name,
    version         = version,
    suite_num       = suite["num"],
    comment         = suite.get("comment", ""),
    harness_include = harness_include,
    param_block     = param_block,
  )

#=========================================================================
# Step: Clean
#=========================================================================

def _clean_dir( path ):
  """
  Delete all contents of ``path`` without removing the directory itself.
  Silently skips if ``path`` does not exist.
  """
  if not path.exists():
    print(f"  not found, skipping: {path}")
    return
  deleted = 0
  for entry in path.iterdir():
    if entry.is_dir():
      shutil.rmtree(entry)
    else:
      entry.unlink()
    deleted += 1
  print(f"  Deleted {deleted} item(s) from {path}")


def step_clean( build_dir ):
  """
  Delete all generated files and the build directory so the next run starts
  from a known-clean state.

  Clears the contents of ELF_SUITES_DIR, TEST_ASM_DIR, GEN_ASM_DIR, and
  BUILD_DIR. The first three directories are emptied but kept; BUILD_DIR is
  emptied and then removed entirely.
  """
  _banner("Clean: removing generated files and build directory")

  _clean_dir(ELF_SUITES_DIR)
  _clean_dir(TEST_ASM_DIR)
  _clean_dir(GEN_ASM_DIR)
  _clean_dir(build_dir)

  if build_dir.exists():
    build_dir.rmdir()
    print(f"  Removed build directory: {build_dir}")

#=========================================================================
# Step: Generate ELF test suite .v files
#=========================================================================

def step_gen_elf():
  """
  Read suite definitions from verif_elf_suites.yaml and write one ``.v``
  file per suite into ELF_SUITES_DIR, then write the ``riscv_dv_elf_suites.cmake``
  manifest listing all generated files.

  Skips writing a file if its content is already up to date (avoids touching
  mtime unnecessarily). Creates ELF_SUITES_DIR if it does not exist.
  """
  _banner("Generating ELF test suite .v files")

  ELF_SUITES_DIR.mkdir(parents=True, exist_ok=True)

  all_rel_paths = []
  total_written = 0
  total_skipped = 0

  for version, meta in _VERSION_META.items():
    suites = meta["suites"]
    print(f"\n  {version}: {len(suites)} suite(s) → {ELF_SUITES_DIR}")

    for suite in suites:
      module_name = f"{version}_elf_test_suite_{suite['num']}"
      out_path    = ELF_SUITES_DIR / f"{module_name}.v"
      rel_path    = f"hw/top/test/riscv_dv_asm/elf_suites/{module_name}.v"
      content     = _generate_v(version, meta["harness_include"], suite)
      all_rel_paths.append(rel_path)

      if out_path.exists() and out_path.read_text() == content:
        print(f"    unchanged  {out_path.name}")
        total_skipped += 1
        continue

      out_path.write_text(content)
      print(f"    wrote      {out_path.name}")
      total_written += 1

  # Write cmake manifest
  cmake_path = ELF_SUITES_DIR / _CMAKE_FILENAME
  lines = [
    f"# {_CMAKE_FILENAME}\n",
    "# Auto-generated by tools/verif_riscv_dv_batch.py -- do not edit by hand.\n\n",
    "set(ELF_SUITE_FILES\n",
  ]
  for p in all_rel_paths:
    lines.append(f"  {p}\n")
  lines.append(")\n")
  cmake_content = "".join(lines)

  if cmake_path.exists() and cmake_path.read_text() == cmake_content:
    print(f"\n  unchanged  {_CMAKE_FILENAME}")
  else:
    cmake_path.write_text(cmake_content)
    print(f"\n  wrote      {_CMAKE_FILENAME}")

  print(f"\n  Wrote {total_written} file(s), skipped {total_skipped} unchanged.")

#=========================================================================
# Step: Set instruction count
#=========================================================================

_INSTR_CNT_RE = re.compile(r'^(\s*)\+instr_cnt=\d+', re.MULTILINE)

def step_set_instr_cnt( n ):
  """
  Replace the active ``+instr_cnt=<N>`` value in every testlist.yaml under
  CUSTOM_TARGETS_DIR with ``n``.

  Only the uncommented line is modified; the commented-out reference entries
  (prefixed with ``#``) are left untouched.

  Args:
    n (int): New instruction count (must be >= 10).
  """
  _banner(f"Setting +instr_cnt={n} in all testlist.yaml files")

  yamls = sorted(CUSTOM_TARGETS_DIR.glob("*/testlist.yaml"))
  if not yamls:
    print(f"  No testlist.yaml files found under {CUSTOM_TARGETS_DIR}")
    return

  for path in yamls:
    original = path.read_text()
    updated  = _INSTR_CNT_RE.sub(rf'\g<1>+instr_cnt={n}', original)
    if updated == original:
      print(f"  unchanged  {path.parent.name}/testlist.yaml")
    else:
      path.write_text(updated)
      print(f"  updated    {path.parent.name}/testlist.yaml")

#=========================================================================
# Step: Compile riscv-dv generator (once)
#=========================================================================

def step_compile_riscv_dv():
  """
  Compile the riscv-dv generator for every custom target using ``--co``.

  Each target gets its own subdirectory under GEN_ASM_DIR so that compiled
  artifacts for different targets remain isolated. Subsequent gen_asm calls
  can then use ``--so`` against the same per-target output directory to skip
  recompilation.
  """
  _check_riscv_dv_clone()
  targets = sorted(p.name for p in CUSTOM_TARGETS_DIR.iterdir() if p.is_dir())

  _banner("Compiling riscv-dv generator for all custom targets (--co)")
  print(f"  cwd    : {RISCV_DV_CLONE_PATH}")
  print(f"  targets: {targets}\n")

  for target in targets:
    out_dir = GEN_ASM_DIR / target
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = list(RISCV_DV_CMD) + [
      "--custom_target", str(CUSTOM_TARGETS_DIR / target),
      "-o",             str(out_dir),
      "--co",
    ]
    print(f"  [{target}] cmd : {' '.join(cmd)}\n")
    _run(cmd, cwd=RISCV_DV_CLONE_PATH)

#=========================================================================
# Step: Generate ASM tests via riscv-dv
#=========================================================================

def step_gen_asm( sim_only=True, seed=None ):
  """
  Invoke riscv-dv once per custom target, writing output into a per-target
  subdirectory of GEN_ASM_DIR (``gen_asm/<target>/``).

  Targets are derived from the subdirectories of CUSTOM_TARGETS_DIR so that
  adding or removing a target directory is automatically reflected without
  editing this script. Raises ``subprocess.CalledProcessError`` if any
  riscv-dv invocation exits non-zero.

  Args:
    sim_only (bool): When True (default), uses ``--so`` to skip recompilation.
      Set to False to use ``--steps=all`` (compile + simulate).
    seed (int | None): Seed for riscv-dv. When None, a deterministic-but-varied
      seed is derived from wall-clock time.

  Returns:
    int: The seed used for all riscv-dv invocations this run.
  """
  _check_riscv_dv_clone()
  targets = sorted(p.name for p in CUSTOM_TARGETS_DIR.iterdir() if p.is_dir())

  flag = "--so" if sim_only else "--steps=all"
  _banner(f"Generating ASM: running riscv-dv ({flag})")
  if seed is None:
    now  = datetime.now()
    seed = int(hashlib.sha256(now.isoformat().encode()).hexdigest(), 16) % (2**31)
    print(f"  cwd    : {RISCV_DV_CLONE_PATH}")
    print(f"  seed   : {seed}  ({now.strftime('%H:%M:%S')})")
  else:
    print(f"  cwd    : {RISCV_DV_CLONE_PATH}")
    print(f"  seed   : {seed}  (provided)")
  print(f"  targets: {targets}\n")

  for target in targets:
    out_dir = GEN_ASM_DIR / target
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = list(RISCV_DV_CMD) + [
      "--custom_target", str(CUSTOM_TARGETS_DIR / target),
      "-o",              str(out_dir),
      flag,
      "--seed",          str(seed),
    ]
    print(f"  [{target}] cmd : {' '.join(cmd)}\n")
    _run(cmd, cwd=RISCV_DV_CLONE_PATH)

  return seed

#=========================================================================
# Step: Transform generated ASM into Zeppelin-compatible assembly
#=========================================================================

def _transform( lines ):
  """
  Convert a riscv-dv generated .S file into a Zeppelin test_entry file.

  Slices the body from ``init:`` up to (not including) ``kernel_instr_start:``,
  renames ``init:`` to ``test_entry:``, and replaces the test-done block
  (``la <reg>, test_done`` ... ``j write_tohost``) with a jump to test_return.
  """
  # Locate init: label
  init_idx = next(
    (i for i, l in enumerate(lines)
     if re.match(r'^init:\s*$', l) or re.match(r'^init:\s+', l)),
    None
  )
  if init_idx is None:
    raise ValueError("Could not find 'init:' label")

  # Locate kernel_instr_start: label
  kernel_idx = next(
    (i for i, l in enumerate(lines)
     if re.match(r'^kernel_instr_start:\s*$', l)
     or re.match(r'^kernel_instr_start:\s+', l)),
    None
  )
  if kernel_idx is None:
    raise ValueError("Could not find 'kernel_instr_start:' label")

  body    = lines[init_idx:kernel_idx]
  body[0] = re.sub(r'^init:', 'test_entry:', body[0])

  # Replace test-done termination block with jump to test_return
  start_idx = next(
    (i for i, l in enumerate(body)
     if re.search(r'\bla\s+\w+,\s*test_done\b', l)),
    None
  )
  end_idx = next(
    (i for i, l in enumerate(body)
     if start_idx is not None and i >= start_idx
     and re.search(r'\bj\s+write_tohost\b', l)),
    None
  )
  if start_idx is None or end_idx is None:
    raise ValueError("Could not find test-done termination block")

  la_line   = re.sub(r'\btest_done\b', 'test_return', body[start_idx])
  jalr_line = body[start_idx + 1]
  body      = body[:start_idx] + [la_line, jalr_line] + body[end_idx + 1:]

  return ['.globl test_entry\n'] + body


def step_transform():
  """
  Convert every ``*.S`` file in each ``gen_asm/<target>/asm_test/``
  subdirectory into a Zeppelin-compatible assembly file and write it to
  TEST_ASM_DIR.

  The transformation strips the kernel preamble, renames ``init:`` to
  ``test_entry:``, and replaces the ``write_tohost`` termination block with a
  jump to ``test_return`` so the file fits Zeppelin's test harness entry/exit
  convention. Files that cannot be transformed (missing expected labels) are
  logged and skipped rather than aborting the run.

  Creates TEST_ASM_DIR if it does not already exist.
  """
  src_dirs = sorted(
    d / "asm_test"
    for d in sorted(GEN_ASM_DIR.iterdir())
    if d.is_dir() and (d / "asm_test").exists()
  ) if GEN_ASM_DIR.exists() else []

  _banner("Transforming riscv-dv output into Zeppelin-compatible assembly")
  print(f"  Input dirs : {[str(d) for d in src_dirs]}")
  print(f"  Output     : {TEST_ASM_DIR}\n")

  if not src_dirs:
    print("  No asm_test/ subdirectories found — run --gen_asm first.",
          file=sys.stderr)
    return

  TEST_ASM_DIR.mkdir(parents=True, exist_ok=True)

  written = 0
  skipped = 0
  for src_dir in src_dirs:
    for src in sorted(src_dir.glob("*.S")):
      dst   = TEST_ASM_DIR / src.name
      lines = src.read_text().splitlines(keepends=True)
      try:
        result = _transform(lines)
      except ValueError as e:
        print(f"  Skipping {src.name}: {e}")
        skipped += 1
        continue
      dst.write_text("".join(result))
      written += 1

  print(f"  Written {written} file(s), skipped {skipped}")

#=========================================================================
# Step: CMake build configuration
#=========================================================================

def step_config_build( parallel ):
  """
  Create a fresh build directory at BUILD_DIR and configure it with CMake.

  Exits with an error if BUILD_DIR already exists — run ``--clean`` first to
  remove it. Configures with ``-DCOVERAGE=1``; all other options use CMake
  defaults. Raises ``subprocess.CalledProcessError`` if ``cmake`` exits
  non-zero.
  """
  _banner(f"Configuring build directory '{BUILD_DIR.name}'")

  if BUILD_DIR.exists():
    print(f"  Error: build directory already exists: {BUILD_DIR}", file=sys.stderr)
    print(f"  Run --clean first to remove it.", file=sys.stderr)
    sys.exit(1)

  BUILD_DIR.mkdir()
  print(f"  Created {BUILD_DIR}\n")
  _run(["cmake", "..", "-DCOVERAGE=1", "-DTRACE=1"], cwd=BUILD_DIR)

  suite_names = sorted(p.stem for p in ELF_SUITES_DIR.glob("*.v"))
  if not suite_names:
    print("\n  No ELF suite .v files found — skipping suite binary build.")
    return

  print(f"\n  Building {len(suite_names)} ELF suite binary/binaries (-j{parallel}) ...")
  subprocess.run(
    ["make", "-k", f"-j{parallel}", "riscv-dv-elf-tests"],
    cwd=str(BUILD_DIR),
  )
  n_ok = sum(1 for name in suite_names if (BUILD_DIR / name).exists())
  print(f"\n  Suite builds: {n_ok}/{len(suite_names)} ok")

#=========================================================================
# Step: Build and run all suite/ASM test pairs
#=========================================================================

def step_run_tests( parallel ):
  """
  Compile/recompile all transformed ASM tests, then run every (suite, ASM)
  pair against the ELF suite binaries already built by ``--config_build``.

  Two sub-phases run sequentially:

  * **1** — Build ``asm-test-<name>`` for every ``.S`` file in TEST_ASM_DIR.
  * **2** — Run every (suite, asm_name) pair in parallel. Pairs where the
    ASM build failed or the suite binary is missing are skipped
    (``run_ok=None``).

  Prints inline PASS/FAIL as tests complete. Returns True if all tests
  passed, False otherwise.

  Args:
    parallel (int): Maximum number of concurrent worker threads.

  Returns:
    bool: True if every test passed, False otherwise.
  """
  _banner("Running ELF suite tests against transformed ASM")

  suite_names = sorted(p.stem for p in ELF_SUITES_DIR.glob("*.v"))
  asm_names   = sorted(p.stem for p in TEST_ASM_DIR.glob("*.S"))

  if not suite_names:
    print("  No ELF suite .v files found — run --gen_elf first.", file=sys.stderr)
    sys.exit(1)
  if not asm_names:
    print("  No ASM tests found — run --transform_asm first.", file=sys.stderr)
    sys.exit(1)

  total_runs = len(suite_names) * len(asm_names)
  print(f"  {len(suite_names)} suite(s) × {len(asm_names)} ASM test(s) = {total_runs} run(s)\n")

  #-------------------------------------------------------------------------
  # Phase 1: Build ASM tests
  #-------------------------------------------------------------------------

  print(f"  [1] Building {len(asm_names)} ASM test(s) (parallel={parallel}) ...")
  subprocess.run(
    ["make", "-k", f"-j{parallel}", "asm-tests"],
    cwd=str(BUILD_DIR),
  )
  asm_build_ok = {}
  for name in asm_names:
    ok = (BUILD_DIR / "riscv_dv_asm" / name).exists()
    asm_build_ok[name] = ok
    print(f"    asm-test-{name}: {'ok' if ok else 'FAIL'}")

  n_asm_ok = sum(asm_build_ok.values())
  print(f"\n  ASM builds: {n_asm_ok}/{len(asm_names)} ok\n")

  # Suite binaries were compiled during --config_build; check existence only.
  suite_build_ok = { name: (BUILD_DIR / name).exists() for name in suite_names }

  #-------------------------------------------------------------------------
  # Phase 2: Run all (suite, asm_name) pairs
  #-------------------------------------------------------------------------

  print(f"  [2] Running {total_runs} test(s) (parallel={parallel}) ...")

  results  = { s: {} for s in suite_names }
  run_lock = threading.Lock()

  def _run_pair( args ):
    suite, asm_name = args
    build_ok = suite_build_ok.get(suite, False) and asm_build_ok.get(asm_name, False)
    r = TestResult(suite=suite, asm_name=asm_name, build_ok=build_ok)

    if not build_ok:
      with run_lock:
        results[suite][asm_name] = r
      return

    elf_path = f"riscv_dv_asm/{asm_name}"
    try:
      proc = subprocess.run(
        [f"./{suite}", f"+elf={elf_path}"],
        cwd=str(BUILD_DIR), capture_output=True, text=True,
        timeout=300,
      )
      r.run_ok = proc.returncode == 0
      r.stdout = proc.stdout
      r.stderr = proc.stderr
    except subprocess.TimeoutExpired as e:
      r.run_ok = False
      r.stdout = e.stdout or ""
      r.stderr = f"TIMEOUT: simulation exceeded 300 s wall-clock limit\n" + (e.stderr or "")

    with run_lock:
      results[suite][asm_name] = r
      mark = "PASS" if r.run_ok else "FAIL"
      print(f"    [{suite}] {asm_name}: {mark}")

  all_pairs = [(s, n) for s in suite_names for n in asm_names]
  with concurrent.futures.ThreadPoolExecutor(max_workers=parallel) as pool:
    list(pool.map(_run_pair, all_pairs))

  overall_pass = all(
    r.run_ok is True
    for s in suite_names
    for r in results[s].values()
  )
  return overall_pass, results

#=========================================================================
# Reporting helpers
#=========================================================================

def _format_report( iteration, seed, instr_cnt, results, timestamp, failures_only=False ):
  """Return a formatted report string for one batch iteration."""
  suite_names = sorted(results.keys())
  rows = [
    (r.status_str(), r.suite, r.asm_name)
    for s in suite_names
    for r in sorted(results[s].values(), key=lambda r: r.asm_name)
  ]

  n_pass    = sum(1 for st, _, _ in rows if st == "PASS")
  n_fail    = sum(1 for st, _, _ in rows if st == "FAIL")
  n_skip    = sum(1 for st, _, _ in rows if st in ("SKIP", "BUILD_ERR"))
  n_total   = len(rows)

  col_suite = max((len(s) for _, s, _ in rows), default=5)
  col_asm   = max((len(a) for _, _, a in rows), default=8)

  sep    = "=" * _WIDTH
  header = (
    f"{sep}\n"
    f"  Batch Iteration {iteration}  —  {timestamp}\n"
    f"  Instruction count : {instr_cnt}\n"
    f"  Seed              : {seed}\n"
    f"{sep}\n\n"
    f"  {'Status':<8}  {'Suite':<{col_suite}}  {'ASM Test'}\n"
    f"  {'------':<8}  {'-'*col_suite}  {'-'*col_asm}\n"
  )
  body = "".join(
    f"  {st:<8}  {suite:<{col_suite}}  {asm}\n"
    for st, suite, asm in rows
    if not failures_only or st != "PASS"
  )
  summary = (
    f"\n  Summary: {n_pass} passed | {n_fail} failed | "
    f"{n_skip} skipped | {n_total} total\n"
    f"{sep}\n"
  )
  return header + body + summary


def _write_report( iteration, seed, instr_cnt, results, timestamp, log_dir ):
  """Write a per-iteration .log file to log_dir and return the report text."""
  log_dir.mkdir(parents=True, exist_ok=True)
  safe_ts  = timestamp.replace(" ", "_").replace(":", "")
  log_path = log_dir / f"iter_{iteration:04d}_{safe_ts}.log"
  text     = _format_report(iteration, seed, instr_cnt, results, timestamp)
  log_path.write_text(text)
  print(f"  Report written: {log_path}")
  return text


def _send_failure_email( report_text, iteration, timestamp, email_to ):
  """Send the report by email when failures are detected."""
  subject = f"[zeppelin-verif] FAILURE in batch iteration {iteration} ({timestamp})"
  msg     = MIMEText(report_text)
  msg["Subject"] = subject
  msg["From"]    = REPORT_EMAIL_FROM
  msg["To"]      = email_to
  try:
    with smtplib.SMTP(REPORT_SMTP_HOST, REPORT_SMTP_PORT, timeout=10) as s:
      s.sendmail(REPORT_EMAIL_FROM, [email_to], msg.as_string())
    print(f"  Failure email sent to {email_to}")
  except Exception as e:
    print(f"  Warning: could not send email ({e})", file=sys.stderr)

#=========================================================================
# Step: Batch (setup + generation/test loop)
#=========================================================================

def step_batch( parallel, skip_setup=False, stop_on_failure=False, max_iterations=1000,
                 email_to=None ):
  """
  Full batch flow: setup once, then loop incrementing instruction count.

  Setup (runs once, skipped when skip_setup=True):
    1. Clean all generated files and the build directory.
    2. Generate ELF test suite .v files.
    3. Configure build and compile all ELF suite binaries.
    4. Compile the riscv-dv generator (--co) so loop iterations skip recompilation.

  Loop (instr_cnt = 10, 20, 30, ...):
    1. Set +instr_cnt=N in all custom-target testlist.yaml files.
    2. Generate ASM via riscv-dv.
    3. Transform generated ASM into Zeppelin-compatible assembly.
    4. Build ASM test binaries and run all (suite, ASM) pairs.
    5. Delete gen_asm/, test_asm/, and BUILD_DIR/riscv_dv_asm/ contents
       so the next iteration starts with a clean slate (BUILD_DIR itself
       is preserved so the ELF suite binaries do not need to be rebuilt).

  Runs for max_iterations iterations, or forever if max_iterations is None (Ctrl+C to stop).
  A failure email is sent only when email_to is not None (see --email).
  """
  # ---- Log directory (one per batch run) -------------------------------
  batch_ts  = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
  batch_log_dir = LOG_DIR / batch_ts
  batch_log_dir.mkdir(parents=True, exist_ok=True)
  print(f"  Log directory  : {batch_log_dir}")

  # ---- Setup -----------------------------------------------------------
  if skip_setup:
    _banner("BATCH  Skipping setup phase (--no_setup)")
  else:
    _banner("BATCH  Setup phase")
    step_clean(BUILD_DIR)
    step_gen_elf()
    step_config_build(parallel)
    step_compile_riscv_dv()

  # ---- Loop ------------------------------------------------------------
  instr_cnt     = 10
  iteration     = 1
  iters_at_cnt  = 0    # phase-1 counter: how many iterations run at current count
  exp_increment = 100  # phase-3 doubling increment, starts at 100

  try:
    while max_iterations is None or iteration <= max_iterations:
      _banner(f"BATCH  Iteration {iteration}  (instr_cnt={instr_cnt})")
      step_set_instr_cnt(instr_cnt)
      seed = step_gen_asm(sim_only=True)
      step_transform()
      ok, results = step_run_tests(parallel)

      timestamp   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
      report_text = _write_report(iteration, seed, instr_cnt, results, timestamp, batch_log_dir)
      if not ok and email_to is not None:
        email_text = _format_report(iteration, seed, instr_cnt, results, timestamp, failures_only=True)
        _send_failure_email(email_text, iteration, timestamp, email_to)
      if not ok:
        if stop_on_failure:
          print(f"\n  Stopping batch after iteration {iteration} due to failure (--stop_on_failure).")
          break

      _banner(f"BATCH  Iteration {iteration} complete — cleaning ASM for next iteration")
      _clean_dir(TEST_ASM_DIR)
      _clean_dir(BUILD_DIR / "riscv_dv_asm")

      # Phase 1 (<100): stay at each count for 10 iterations, then +10
      if instr_cnt < 100:
        iters_at_cnt += 1
        if iters_at_cnt >= 15:
          instr_cnt    += 10
          iters_at_cnt  = 0
      # Phase 2 (100–999): +10 every iteration
      elif instr_cnt < 1000:
        instr_cnt += 10
      # Phase 3 (>=1000): doubling increment, saturate at 100k
      elif instr_cnt < 100_000:
        instr_cnt     = min(instr_cnt + exp_increment, 100_000)
        exp_increment = min(int(exp_increment * 1.2), 100_000)

      iteration += 1

  except KeyboardInterrupt:
    print(f"\n\n  Batch interrupted after iteration {iteration - 1}.")
    return

  if max_iterations is not None and iteration > max_iterations:
    print(f"\n  Batch complete — reached bound of {max_iterations} iteration(s).")

#=========================================================================
# main
#=========================================================================

def main():
  parser = argparse.ArgumentParser(
    description="Batch riscv-dv ELF test runner for ZeppelinV8/V11"
  )
  parser.add_argument(
    "--clean", action="store_true",
    help="Delete generated files and the build directory, then exit"
  )
  parser.add_argument(
    "--gen_elf", action="store_true",
    help="Generate ELF test suite .v files and cmake manifest from VH files, then exit"
  )
  parser.add_argument(
    "--instr_cnt", type=int, metavar="N",
    help="Set +instr_cnt=N in every custom_target testlist.yaml (N >= 10), then exit"
  )
  parser.add_argument(
    "--gen_asm", action="store_true",
    help="Run riscv-dv for all custom targets and write raw output to gen_asm/, then exit"
  )
  parser.add_argument(
    "--seed", type=int, default=None, metavar="SEED",
    help="With --gen_asm: seed for riscv-dv (default: auto-generated from wall-clock time)"
  )
  parser.add_argument(
    "--transform_asm", action="store_true",
    help="Transform gen_asm/asm_test/*.S into Zeppelin-compatible assembly in test_asm/, then exit"
  )
  parser.add_argument(
    "--config_build", action="store_true",
    help="Create BUILD_DIR and configure it with 'cmake .. -DCOVERAGE=1', then exit"
  )
  parser.add_argument(
    "--compile_riscv_dv", action="store_true",
    help="Compile the riscv-dv generator once (--co), then exit"
  )
  parser.add_argument(
    "--run_tests", action="store_true",
    help="Build all ELF suite binaries and ASM tests, then run every (suite, ASM) pair"
  )
  parser.add_argument(
    "--batch", action="store_true",
    help="Full batch flow: setup once (clean + gen_elf + config_build), "
         "then loop forever with instr_cnt=10,20,30,... running gen_asm, "
         "transform_asm, and run_tests each iteration (Ctrl+C to stop)"
  )
  parser.add_argument(
    "--no_setup", action="store_true",
    help="With --batch: skip the setup phase (clean + gen_elf + config_build) "
         "and jump straight into the generation/test loop"
  )
  parser.add_argument(
    "--stop_on_failure", action="store_true",
    help="With --batch: stop the loop immediately if any test in an iteration fails "
         "(default: continue regardless of failures)"
  )
  bound_group = parser.add_mutually_exclusive_group()
  bound_group.add_argument(
    "--bound", type=int, metavar="N", default=300,
    help="With --batch: stop after N iterations (default: 300)"
  )
  bound_group.add_argument(
    "--unbound", action="store_true",
    help="With --batch: run forever until interrupted (mutually exclusive with --bound)"
  )
  parser.add_argument(
    "--parallel", type=int, default=1,
    help="Number of parallel compile/run workers (default: 1)"
  )
  parser.add_argument(
    "--riscv_dv_path", type=Path, default=DEFAULT_RISCV_DV_PATH, metavar="PATH",
    help=f"Path to a riscv-dv checkout (default: {DEFAULT_RISCV_DV_PATH}). "
         "Only checked for steps that invoke riscv-dv "
         "(--compile_riscv_dv, --gen_asm, --batch)."
  )
  parser.add_argument(
    "--build_dir", type=Path, default=DEFAULT_BUILD_DIR, metavar="PATH",
    help=f"CMake build directory to create/use (default: {DEFAULT_BUILD_DIR})"
  )
  parser.add_argument(
    "--email", default=None, metavar="ADDRESS",
    help="Email address to send failure reports to during --batch. "
         "No email is sent unless this is given (default: none)."
  )
  args = parser.parse_args()

  global RISCV_DV_CLONE_PATH, BUILD_DIR
  RISCV_DV_CLONE_PATH = args.riscv_dv_path.expanduser().resolve()
  BUILD_DIR            = args.build_dir.expanduser().resolve()

  build_dir = BUILD_DIR

  if args.clean:
    step_clean(build_dir)
    sys.exit(0)

  if args.gen_elf:
    step_gen_elf()
    sys.exit(0)

  if args.instr_cnt is not None:
    if args.instr_cnt < 10:
      parser.error("--instr_cnt must be >= 10")
    step_set_instr_cnt(args.instr_cnt)
    sys.exit(0)

  if args.compile_riscv_dv:
    step_compile_riscv_dv()
    sys.exit(0)

  if args.gen_asm:
    step_gen_asm(seed=args.seed)
    sys.exit(0)

  if args.transform_asm:
    step_transform()
    sys.exit(0)

  if args.config_build:
    step_config_build(args.parallel)
    sys.exit(0)

  if args.run_tests:
    ok, _ = step_run_tests(args.parallel)
    sys.exit(0 if ok else 1)

  if args.batch:
    max_iterations = None if args.unbound else args.bound
    step_batch(args.parallel, skip_setup=args.no_setup, stop_on_failure=args.stop_on_failure,
               max_iterations=max_iterations, email_to=args.email)
    sys.exit(0)

  print("Nothing to do yet. Pass --batch, --clean, --gen_elf, --gen_asm, --transform_asm, --config_build, --run_tests, or --instr_cnt N.")


if __name__ == "__main__":
  main()
