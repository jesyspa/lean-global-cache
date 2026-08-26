# Test Suite Measurement Analysis

## Current Baseline
- **Wall time (full suite, parallel)**: 29 seconds
- **Previous baseline**: ~79 seconds (improvement noted in comments)
- **Groups**: 24 (main tier), 1 (nightly tier)
- **Test assertions**: 296 total

## Per-Group Timing (Sequential Execution)
When run individually, groups take:
- Slowest: `group_slots` (32.8s), `group_static` (25.4s), `group_elanwire` (25.4s)
- Fastest: `group_pubpush` (18.8s), `group_seed` (19.8s), `group_policy` (20.0s)
- Average: ~22 seconds per group

## Issues Identified

### 1. Shellcheck Performance - group_static
- **Measured**: Shellcheck on CLI (2151 lines) alone takes 7.8 seconds
- **Issue**: group_static runs shellcheck on multiple files (CLI, lake-shim, deploy.sh, test.sh, config.sh, admin scripts)
- **Estimated cost**: ~25 seconds for the full shellcheck battery
- **Impact**: This is a linting/static check, not a functional test. Its cost on every deploy is high.
- **Fix opportunity**: Consider running shellcheck separately or caching results

### 2. New Cache Overhead
- Each group calls `new_cache()` which creates temp directories
- Groups have varying workloads but all call this function
- The temp cleanup via `trap 'rm -rf "$TMP"' EXIT` might be slow with large directories
- Some groups create many files/directories (especially install, seed, policy groups)

### 3. CLI Invocation Frequency
- Each group averages ~11 test assertions (296 total / 27 groups)
- Each assertion often involves calling `$CLI` with different commands
- Single CLI invocation: ~58ms (acceptable)
- With subprocess overhead (pipes, greps, command substitution), assertions take 2+ seconds total in some cases

### 4. Test Structure Efficiency
- 296 assertions spread across 27 groups
- Some groups might have unnecessarily complex assertion chains
- Each `check` function evaluates complex shell expressions with nested command substitution

## Compliance with Standards

### Hermetic: ✓ PASS
- Each group has isolated temp dir, LEAN_CACHE_ROOT, HOME, build lock dir
- No shared state between groups
- No real Lean/Lake builds (uses stubs)

### No Real Clock: ✓ PASS
- No `date` calls for timing
- No sleep commands observed in functional tests
- Uses actual filesystem for fixtures instead of mocking time

### Avoid Subprocesses: ⚠️ MIXED
- Good: Uses bash builtins where possible
- Issue: Heavy use of command substitution in test assertions
  - Each `check` calls the CLI multiple times
  - Heavy piping through grep/awk/printf for output parsing
- Each group is a subshell spawned by `run_group()`

### Cost Budget (0.1s per test max): ✗ FAIL
- Individual groups take ~22s average
- Per-assertion: ~75ms on average (within budget)
- But per-group cost is 20-32s, which violates the spirit of the budget
- Wall time is good (29s parallel) but sequential execution is slow

## Root Cause Analysis

The slowness is primarily due to:

1. **Shellcheck in group_static**: Static analysis takes ~7+ seconds per run
2. **Process spawning overhead**: Each test setup creates new processes (git, mkdir, chmod, etc.)
3. **Sequential subprocess dependencies**: Each assertion waits for previous operations
4. **Large temp directory cleanup**: Some groups create many test fixtures

## Measurement Methodology

Groups were measured by sourcing test.sh and calling each group function individually in a separate bash subprocess. Total wall time was 29 seconds when run with full parallelism (TEST_JOBS default).

## Remaining Investigation

Not yet identified:
- Whether individual group slowness causes deploy gate delays
- Whether parallel execution is constrained by I/O or CPU
- Exact breakdown of time within each group (which operations are slowest)
