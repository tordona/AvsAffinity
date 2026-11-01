# AvsAffinity v1.0.0 Release Notes

Initial public release of **AvsAffinity**, an open-source AviSynth+ clip filter that enforces CPU Performance core (P-core) thread affinity for multi-threaded `Prefetch()` pipelines across hybrid processor topologies.

---

## Technical Overview

On hybrid processor topologies (e.g. Intel Alder/Raptor/Arrow Lake, Snapdragon ARM64, AMD Zen 4c/5c), the Windows thread scheduler can migrate compute-intensive video worker threads onto low-IPC Efficiency cores (E-cores). For real-time frame interpolation (e.g. 24 fps -> 60 fps) and heavy video filtering, this migration introduces frame presentation jitter, increased 1% low frame latency, and pipeline starvation.

`AvsAffinity` solves this problem at the AviSynth clip filter level:
* **Worker Confinement:** Uses Win32 `SetThreadAffinityMask` on worker threads during `GetFrame()` traversal with thread-local caching, executing exactly once per worker thread lifetime.
* **Preserved Host Concurrency:** Host media player threads—including audio decoding, UI event loops, DXVA video acceleration, and Direct3D swapchain presentation—remain unconstrained and free to run on Efficiency cores.
* **Zero State Leakage:** Thread affinity terminates automatically with the AviSynth environment upon playlist transitions or file close events.
* **Homogeneous Processor Bypass:** When executed on processors with uniform core efficiency (e.g. Intel N100 all-E-core CPUs, standard AMD Ryzen CCDs, Snapdragon X Elite), `EfficiencyClass` is identical across all logical processors. The filter detects this and executes a safe no-op (`mask = 0x0`) without error or modification to system affinity.

---

## Filter Interface

### `PinWorkerThreads(clip c, string "mask", bool "strictPrime", bool "debug")`
Intercepts `GetFrame()` to isolate executing AviSynth+ worker threads to Performance cores.
* `mask` (optional, default `""`): Hexadecimal (e.g. `"0x00FF"`) or decimal bitmask. If omitted, discovered automatically via `GetLogicalProcessorInformationEx`.
* `strictPrime` (optional, default `false`): On 3-tier CPUs (such as Snapdragon 8cx Gen 3 with Cortex-X1 Prime cores), restricts threads strictly to the highest efficiency tier when `true`. When `false`, includes all cores above baseline efficiency.
* `debug` (optional, default `false`): Outputs topology discovery and thread pinning events via `OutputDebugStringA`.

### `GetPCoreMask(bool "strictPrime") -> string`
Introspection function returning the detected Performance core bitmask as a hexadecimal string (e.g. `"0x00FF"` or `"0x0"` on homogeneous CPUs).

### `SetProcessAffinity(string "mask") -> bool`
Utility function setting the global process affinity mask for command-line batch encoding pipelines (`ffmpeg`, `avs2pipemod`).

---

## Recommended Integration Pattern

```avs
# Frame interpolation / filtering pipeline
super = MSuper(pel=1, hpad=16, vpad=16)
bvec  = MAnalyse(super, isb=true,  blksize=16)
fvec  = MAnalyse(super, isb=false, blksize=16)
last  = MFlowFps(super, bvec, fvec, num=60, den=1)

# Isolate lookahead worker threads to P-cores (with backward-compatible fallback)
last  = FunctionExists("PinWorkerThreads") ? last.PinWorkerThreads() : last

# Lookahead concurrency pool
Prefetch(8, 4)
```

---

## Release Artifacts & Dedicated Checksums

| Package | Architecture | Checksum Manifest |
| :--- | :--- | :--- |
| `AvsAffinity-v1.0.0-win-x64.zip` | Windows x86-64 | `AvsAffinity-v1.0.0-win-x64.sha256` |
| `AvsAffinity-v1.0.0-win-arm64.zip` | Windows ARM64 (AArch64) | `AvsAffinity-v1.0.0-win-arm64.sha256` |
| `AvsAffinity-v1.0.0-windows.zip` | Universal Bundle (`x64` + `ARM64`) | `AvsAffinity-v1.0.0-windows.sha256` |

### Integrity Verification (PowerShell)
```powershell
# Verify an individual archive against its companion checksum file
$hash = (Get-FileHash AvsAffinity-v1.0.0-win-x64.zip -Algorithm SHA256).Hash.ToLower()
$expected = (Get-Content AvsAffinity-v1.0.0-win-x64.sha256).Split(' *')[0].ToLower()
if ($hash -eq $expected) { Write-Host "Checksum Verified" -ForegroundColor Green }
```
