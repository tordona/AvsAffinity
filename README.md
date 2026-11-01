# AvsAffinity

An AviSynth+ clip filter that enforces CPU Performance core (P-core) thread affinity for multi-threaded `Prefetch()` pipelines across hybrid architectures (Intel Alder/Raptor Lake, AMD Zen 4c/5c, and Qualcomm Snapdragon ARM64).

---

## Architectural Purpose

On hybrid processor topologies, the operating system thread scheduler (e.g. Windows Thread Director) can migrate compute-intensive video worker threads onto low-IPC Efficiency cores (E-cores). For real-time frame interpolation (e.g. 24 fps $\rightarrow$ 60 fps) and heavy video filtering, this migration introduces frame presentation jitter, increased 1% low frame latency, and pipeline starvation.

Unlike process-level affinity tools (such as Windows `start /affinity` or Process Lasso), which force the **entire application**—including audio decoding, UI event loops, and Direct3D presentation swapchains—onto P-cores, `AvsAffinity` operates as an **AviSynth Clip Filter**:

* Intercepts `GetFrame()` on each executing `Prefetch` worker thread.
* Invokes Win32 `SetThreadAffinityMask` using thread-local caching (executing the system call exactly once per worker thread lifetime).
* **Confinement without Blast Radius:** Video compute threads are restricted strictly to Performance cores, while host audio, subtitle, and UI presentation threads remain free to schedule across Efficiency cores.
* **Zero State Leakage:** Thread affinity terminates automatically with the AviSynth environment upon playlist changes or video close events.

---

## Filter Reference

### `PinWorkerThreads(clip c, string "mask", bool "strictPrime", bool "debug")`

Pins all AviSynth+ worker threads traversing the filter graph to Performance cores.

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `c` | `clip` | *(Required)* | Input video clip. |
| `mask` | `string` | `""` | Optional manual hexadecimal (e.g. `"0x00FF"`) or decimal bitmask. If omitted, topology is detected automatically via `GetLogicalProcessorInformationEx`. |
| `strictPrime` | `bool` | `false` | When `true` on 3-tier CPUs (such as Snapdragon 8cx Gen 3 with Cortex-X1 Prime cores), restricts threads strictly to the highest efficiency class. When `false`, isolates all cores above baseline efficiency. |
| `debug` | `bool` | `false` | When `true`, outputs topology discovery and thread pinning events to the debugger via `OutputDebugStringA`. |

### `GetPCoreMask(bool "strictPrime") -> string`

Introspection function that returns the detected Performance core bitmask as a hexadecimal string (e.g. `"0x00FF"` or `"0x0"` on homogeneous CPUs).

### `SetProcessAffinity(string "mask") -> bool`

Optional utility to set the global process affinity mask for command-line batch encoding pipelines (e.g. `ffmpeg` or `avs2pipemod`).

---

## Script Integration & Fallback Pattern

To ensure scripts remain 100% backward-compatible on systems where `AvsAffinity.dll` is not installed, use AviSynth's built-in `FunctionExists()` check:

```avs
# Frame interpolation / filtering pipeline
super = MSuper(pel=1, hpad=16, vpad=16)
bvec  = MAnalyse(super, isb=true,  blksize=16)
fvec  = MAnalyse(super, isb=false, blksize=16)
last  = MFlowFps(super, bvec, fvec, num=60, den=1)

# Hardware Thread Affinity Pinning (with safe fallback)
last  = FunctionExists("PinWorkerThreads") ? last.PinWorkerThreads() : last

# Lookahead concurrency pool
Prefetch(8, 4)
```

---

## Behavior on Homogeneous Processors

On processors where all cores share identical architecture (e.g. Intel Processor N100 all-E-core CPUs, AMD Ryzen 5000/7000/9000 standard CCDs, Intel 10th/11th Gen, or Snapdragon X Elite/Plus), Windows reports `EfficiencyClass = 0` for all logical processors.

`AvsAffinity` automatically detects `minClass == maxClass` and evaluates to a **safe no-op** (`mask = 0x0`). Affinity remains unconstrained and the pipeline runs across all available cores without error.

---

## Building from Source

### Visual Studio (MSBuild)
Open `AvsAffinity.vcxproj` in Visual Studio 2022 / Build Tools:
```powershell
# Build x64 Release
msbuild AvsAffinity.vcxproj /p:Configuration=Release /p:Platform=x64

# Build ARM64 Release
msbuild AvsAffinity.vcxproj /p:Configuration=Release /p:Platform=ARM64
```

### CMake (Ninja / MSVC / Clang)
```powershell
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

---

## License

This project is licensed under the **MIT License**. See [`LICENSE`](LICENSE) for details.

The AviSynth interface headers (`include/avisynth.h`) are Copyright (C) Ben Rudiak-Gould et al. / AviSynth+ Project and distributed under GNU GPL v2.0 with the official AviSynth Plugin Interface Exception.
