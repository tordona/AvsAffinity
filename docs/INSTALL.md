# AvsAffinity Installation & Integration Guide

This guide details deployment, installation, and integration workflows for `AvsAffinity.dll` across media players, AviSynth+ installations, and automated video processing pipelines.

---

## 1. System Requirements

* **Operating System:** Windows 10 / Windows 11 (Version 1709 or newer for full `GetLogicalProcessorInformationEx` topology features).
* **Architecture:** `x64` (x86-64 / AMD64) or `ARM64` (AArch64).
* **AviSynth+ Runtime:** AviSynth+ v3.7.2 or newer (64-bit `x64` or `ARM64`).
* **Target Hardware:** Hybrid multicore processors:
  * Intel Alder Lake (12th Gen), Raptor Lake (13th/14th Gen), Arrow Lake (15th Gen).
  * AMD Zen 4c / Zen 5c asymmetric CCD topologies.
  * Qualcomm Snapdragon 8cx Gen 1/2/3, Snapdragon 850, Snapdragon 7c Gen 2.
  * *Note:* On homogeneous processors (Intel N100, AMD Ryzen standard CCDs, Snapdragon X Elite), the filter detects uniform core efficiency and acts as a no-op.

---

## 2. Binary Installation

### Option A: Standard AviSynth+ Autoload Directory (Recommended)
Place `AvsAffinity.dll` into the standard AviSynth+ 64-bit plugin directory:

* **Default Path:** `C:\Program Files\AviSynth+\plugins64\` or `C:\Program Files\AviSynth+\plugins+`

When placed in this directory, AviSynth+ automatically loads the plugin upon initialization. Script calls do not require an explicit `LoadPlugin()` statement.

### Option B: Portable / Script-Relative Manual Loading
If running in a standalone or portable environment, load the plugin explicitly at the top of your `.avs` script:

```avs
# Explicitly load binary matching your host process architecture
LoadPlugin("C:\Path\To\AvsAffinity.dll")
```

To ensure fallback capability when distributing scripts across systems where the binary might not be present:

```avs
try {
    LoadPlugin("C:\Path\To\AvsAffinity.dll")
} catch(e) {
    # Plugin not found or architecture mismatch; continues without pinning
}
```

---

## 3. Media Player Configuration

### PotPlayer Integration

1. Open **PotPlayer Preferences** (`F5`).
2. Navigate to **Filter Control $\rightarrow$ Video Processing $\rightarrow$ AviSynth**.
3. Enable AviSynth processing:
   * Set **Execute Condition** to `Always Use` (or your preferred trigger).
   * Ensure the architecture of PotPlayer (`64-bit` vs `32-bit`) matches `AvsAffinity.dll`.
4. In the AviSynth script text editor, insert `PinWorkerThreads()` immediately before the `Prefetch` call:

```avs
# PotPlayer Real-Time Frame Interpolation Pipeline
SetFilterMTMode("DEFAULT_MT_MODE", 2)

# Source frame acquisition
last = PotPlayerSource()

# Video filter / motion vector pipeline (e.g. 24 fps -> 60 fps)
super = MSuper(pel=1, hpad=16, vpad=16)
bvec  = MAnalyse(super, isb=true,  blksize=16)
fvec  = MAnalyse(super, isb=false, blksize=16)
last  = MFlowFps(super, bvec, fvec, num=60, den=1)

# Isolate lookahead worker threads to Performance cores
last = FunctionExists("PinWorkerThreads") ? last.PinWorkerThreads() : last

# Lookahead concurrency pool
Prefetch(8, 4)
```

5. Click **Apply** and **OK**.

### MPC-HC / MPC-BE Integration via ffdshow / AviSynth

1. Open **MPC-HC Options** (`O`).
2. Under **Internal Filters** or **External Filters**, configure `ffdshow Video Decoder` or an AviSynth-enabled source filter.
3. In the AviSynth configuration section, chain `PinWorkerThreads()` before `Prefetch()` as demonstrated above.

---

## 4. Command-Line & Headless Encoding Pipelines

For command-line batch encoding with `avs2pipemod`, `ffmpeg`, or `vspipe`:

### Worker Thread Confinement (Default)
When invoking `ffmpeg` with AviSynth source inputs:
```cmd
ffmpeg -i script.avs -c:v libx265 -crf 18 output.mp4
```
`PinWorkerThreads()` ensures all internal AviSynth filter worker threads are restricted to P-cores, leaving FFmpeg's container muxing and audio encoder threads free to execute across any available cores.

### Process-Wide Pinning (`SetProcessAffinity`)
For batch workflows where the entire process tree must be confined to P-cores:

```avs
# Restrict the entire process to P-cores discovered via Win32 topology API
dummy = FunctionExists("SetProcessAffinity") ? SetProcessAffinity() : false

# Remainder of script...
```

---

## 5. Architectural Verification & Introspection

To verify core topology detection and active masks within AviSynth:

```avs
# Create a dummy blank clip
BlankClip(width=1280, height=720, pixel_type="YV12", fps=60, length=100)

# Query detected Performance core bitmask
maskStr = FunctionExists("GetPCoreMask") ? GetPCoreMask() : "N/A"

# Render detected bitmask onto video overlay
Subtitle("Detected P-Core Bitmask: " + maskStr, size=32, align=5)
```

On an Intel Core i3-1215U (2 P-cores / 4 threads + 4 E-cores = 8 logical processors), `GetPCoreMask()` returns `0x0F` (logical processors 0–3).
