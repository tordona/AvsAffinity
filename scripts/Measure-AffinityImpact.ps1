#Requires -Version 5.1
<#
.SYNOPSIS
    Measures the frame pacing and throughput impact of PinWorkerThreads() (A/B comparison).

.DESCRIPTION
    Generates two AviSynth+ scripts that are identical except for the PinWorkerThreads() call,
    then renders each one in an isolated child process through the AviSynth+ C API
    (avs_get_frame), recording the wall-clock duration of every frame request.

    Each configuration runs in a fresh process so thread-local affinity state from one run
    cannot leak into the next. Trial order alternates (A-B, B-A, ...) to counterbalance
    thermal and boost-clock drift.

    Modes:
      * Paced      - Requests frames at a fixed cadence (default 60 fps), as a media player
                     does. Reports late frames, 1% / 0.1% low FPS, and p99 request latency.
                     This is the mode that corresponds to the real-time playback use case.
      * Throughput - Requests frames as fast as possible. Reports Avg FPS. Pinning restricts
                     the worker pool to a subset of cores, so lower throughput is expected here.
      * Both       - Runs Paced, then Throughput.

    Workloads:
      * MFlowFps   - MVTools2 24 fps -> TargetFps interpolation (1080p, pel=2, search=3,
                     blksize=-BlockSize, overlap=BlockSize/4). Requires mvtools2.dll
                     (autoloaded or via -MvToolsDll).
      * Builtin    - Core-only Spline64Resize / Sharpen / Blur chain (no external plugins).
      * Auto       - MFlowFps if MSuper is available, otherwise Builtin.

    Calibration:
      Paced mode only shows a difference when the workload is close to the CPU's real-time
      capacity. With large headroom, Prefetch() lookahead hides all scheduling effects and both
      configurations report 0 late frames. Run -Mode Throughput first and adjust -BlockSize
      (16 -> 8 is roughly 3x-4x the cost), -SourceScript, or -BackgroundLoad until the unpinned
      Avg FPS is about 1.2x-1.6x TargetFps.

    Results are written as a Markdown report plus a raw JSON file.

.PARAMETER DllPath
    Path to AvsAffinity.dll. Defaults to <RepoRoot>\<arch>\Release\AvsAffinity.dll.

.PARAMETER AviSynthDll
    Path to AviSynth.dll. Defaults to %SystemRoot%\System32\AviSynth.dll.
    Must match the architecture of the PowerShell process running this script.

.PARAMETER MvToolsDll
    Optional explicit path to mvtools2.dll. If omitted, AviSynth+ autoloading is used.

.PARAMETER SourceScript
    Optional AviSynth expression that returns the source clip, e.g.
    'LWLibavVideoSource("D:\clips\pan_1080p24.mkv")'. Real content is recommended for
    published numbers. Defaults to a synthetic ColorBarsHD(1920, 1080) clip.

.PARAMETER Workload
    Auto | MFlowFps | Builtin. Default: Auto.

.PARAMETER Mode
    Paced | Throughput | Both. Default: Paced.

.PARAMETER BlockSize
    MAnalyse block size for the MFlowFps workload: 8, 16, or 32. Default: 16.
    Smaller blocks increase CPU cost per frame.

.PARAMETER TargetFps
    Output frame rate and pacing cadence. Default: 60.

.PARAMETER Frames
    Measured output frames per run (after warmup). Default: 1800 (30 s at 60 fps).

.PARAMETER WarmupFrames
    Frames rendered before measurement starts. Default: 120.

.PARAMETER Trials
    Number of A/B trial pairs per mode. Default: 3.

.PARAMETER Threads
    Prefetch() worker thread count. Default: 0 (= logical processor count).

.PARAMETER BackgroundLoad
    Number of busy-loop threads to run in the parent process at normal priority during
    measurement, to simulate competing applications. Default: 0.

.PARAMETER Mask
    Optional explicit mask passed to PinWorkerThreads(mask=...). Default: auto-detect.

.PARAMETER StrictPrime
    Passes strictPrime=true to PinWorkerThreads() / GetPCoreMask().

.PARAMETER CooldownSeconds
    Idle time between runs. Default: 5.

.PARAMETER OutputMarkdown
    Report path. Default: <RepoRoot>\out\benchmarks\AffinityImpact-<timestamp>.md (git-ignored).

.PARAMETER KeepScripts
    Keep the generated .avs scripts next to the report.

.EXAMPLE
    .\scripts\Measure-AffinityImpact.ps1

.EXAMPLE
    .\scripts\Measure-AffinityImpact.ps1 -Mode Both -BackgroundLoad 4 -Trials 5

.EXAMPLE
    .\scripts\Measure-AffinityImpact.ps1 -SourceScript 'LWLibavVideoSource("D:\clips\pan.mkv")'

.NOTES
    Version:  1.0.0
    Date:     2026-11-04
    Changelog: Initial release. A/B harness with paced and throughput modes, per-process
               isolation, alternating trial order, background load generator, Markdown/JSON output.
#>
[CmdletBinding()]
param(
    [string]$DllPath,
    [string]$AviSynthDll,
    [string]$MvToolsDll,
    [string]$SourceScript,
    [ValidateSet('Auto', 'MFlowFps', 'Builtin')]
    [string]$Workload = 'Auto',
    [ValidateSet('Paced', 'Throughput', 'Both')]
    [string]$Mode = 'Paced',
    [ValidateSet(8, 16, 32)]
    [int]$BlockSize = 16,
    [ValidateRange(1, 1000)]
    [double]$TargetFps = 60,
    [ValidateRange(10, 1000000)]
    [int]$Frames = 1800,
    [ValidateRange(0, 100000)]
    [int]$WarmupFrames = 120,
    [ValidateRange(1, 100)]
    [int]$Trials = 3,
    [ValidateRange(0, 1024)]
    [int]$Threads = 0,
    [ValidateRange(0, 1024)]
    [int]$BackgroundLoad = 0,
    [string]$Mask = '',
    [switch]$StrictPrime,
    [ValidateRange(0, 600)]
    [int]$CooldownSeconds = 5,
    [string]$OutputMarkdown,
    [switch]$KeepScripts,

    # Internal: child-process worker mode
    [switch]$WorkerMode,
    [string]$WorkerScript,
    [string]$WorkerResult,
    [double]$WorkerPaceFps = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

# -----------------------------------------------------------------------------
# Native helpers (AviSynth+ C API host, precise pacing, load generator, topology)
# -----------------------------------------------------------------------------
$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public static class MaiNative {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibraryW(string path);

    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint period);
    [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint period);

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);

    public static string PowerSource() {
        SYSTEM_POWER_STATUS s;
        if (!GetSystemPowerStatus(out s)) return "Unknown";
        if (s.ACLineStatus == 0) return "Battery (" + s.BatteryLifePercent + "%)";
        if (s.ACLineStatus == 1) return "AC";
        return "Unknown";
    }
}

public static class MaiTopology {
    const int RelationProcessorCore = 0;

    [StructLayout(LayoutKind.Sequential)]
    struct GROUP_AFFINITY {
        public UIntPtr Mask;
        public ushort Group;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)]
        public ushort[] Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESSOR_RELATIONSHIP {
        public byte Flags;
        public byte EfficiencyClass;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 20)]
        public byte[] Reserved;
        public ushort GroupCount;
        public GROUP_AFFINITY GroupMask;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct SLPI_EX {
        public int Relationship;
        public int Size;
        public PROCESSOR_RELATIONSHIP Processor;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetLogicalProcessorInformationEx(int rel, IntPtr buffer, ref uint length);

    // Returns one entry per physical core: [efficiencyClass, mask, smtFlag]
    public static List<ulong[]> Cores() {
        var list = new List<ulong[]>();
        uint len = 0;
        GetLogicalProcessorInformationEx(RelationProcessorCore, IntPtr.Zero, ref len);
        if (len == 0) return list;
        IntPtr buf = Marshal.AllocHGlobal((int)len);
        try {
            if (!GetLogicalProcessorInformationEx(RelationProcessorCore, buf, ref len)) return list;
            int off = 0;
            while (off < len) {
                var item = (SLPI_EX)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + off), typeof(SLPI_EX));
                if (item.Relationship == RelationProcessorCore) {
                    list.Add(new ulong[] {
                        item.Processor.EfficiencyClass,
                        (ulong)item.Processor.GroupMask.Mask,
                        item.Processor.Flags
                    });
                }
                off += item.Size;
            }
        } finally {
            Marshal.FreeHGlobal(buf);
        }
        return list;
    }
}

public static class MaiLoad {
    static volatile bool running;
    static readonly List<Thread> threads = new List<Thread>();

    public static void Start(int count) {
        running = true;
        for (int i = 0; i < count; i++) {
            var t = new Thread(Spin);
            t.IsBackground = true;
            t.Priority = ThreadPriority.Normal;
            t.Start();
            threads.Add(t);
        }
    }

    static void Spin() {
        double x = 1.0001;
        while (running) {
            for (int k = 0; k < 200000; k++) { x = x * 1.0000001 + 0.0000001; }
            if (x > 1e300) x = 1.0001;
        }
    }

    public static void Stop() {
        running = false;
        foreach (var t in threads) t.Join(2000);
        threads.Clear();
    }
}

public sealed class MaiRunResult {
    public double[] LatencyMs;
    public double[] FrameTimeMs;
    public int Late;
    public int Measured;
    public double ElapsedSec;
}

public sealed class MaiAvsSession : IDisposable {
    const string AVS = "AviSynth";

    [StructLayout(LayoutKind.Explicit, Size = 16)]
    public struct AVS_Value {
        [FieldOffset(0)] public short type;
        [FieldOffset(2)] public short array_size;
        [FieldOffset(8)] public IntPtr ptr;
        [FieldOffset(8)] public int integer;
    }

    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr avs_create_script_environment(int version);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern void avs_delete_script_environment(IntPtr env);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern AVS_Value avs_invoke(IntPtr env, [MarshalAs(UnmanagedType.LPStr)] string name, AVS_Value args, IntPtr argNames);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr avs_take_clip(AVS_Value v, IntPtr env);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern void avs_release_value(AVS_Value v);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr avs_get_video_info(IntPtr clip);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr avs_get_frame(IntPtr clip, int n);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern void avs_release_video_frame(IntPtr frame);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern IntPtr avs_clip_get_error(IntPtr clip);
    [DllImport(AVS, CallingConvention = CallingConvention.Cdecl)]
    static extern void avs_release_clip(IntPtr clip);

    IntPtr env;
    IntPtr clip;
    public int Width, Height, NumFrames;
    public uint FpsNum, FpsDen;

    public MaiAvsSession(string aviSynthDll, string scriptPath) {
        if (!string.IsNullOrEmpty(aviSynthDll)) {
            if (MaiNative.LoadLibraryW(aviSynthDll) == IntPtr.Zero)
                throw new Exception("LoadLibrary failed for '" + aviSynthDll + "' (Win32 error " + Marshal.GetLastWin32Error() + ").");
        }
        env = avs_create_script_environment(6);
        if (env == IntPtr.Zero) throw new Exception("avs_create_script_environment returned NULL.");

        AVS_Value v = InvokeString("Import", scriptPath);
        try {
            if (v.type == (short)'e') throw new Exception("AviSynth error: " + Marshal.PtrToStringAnsi(v.ptr));
            if (v.type != (short)'c') throw new Exception("Script did not return a clip (type '" + (char)v.type + "').");
            clip = avs_take_clip(v, env);
        } finally {
            avs_release_value(v);
        }
        IntPtr err = avs_clip_get_error(clip);
        if (err != IntPtr.Zero) throw new Exception("AviSynth clip error: " + Marshal.PtrToStringAnsi(err));

        IntPtr vi = avs_get_video_info(clip);
        Width = Marshal.ReadInt32(vi, 0);
        Height = Marshal.ReadInt32(vi, 4);
        FpsNum = (uint)Marshal.ReadInt32(vi, 8);
        FpsDen = (uint)Marshal.ReadInt32(vi, 12);
        NumFrames = Marshal.ReadInt32(vi, 16);
    }

    AVS_Value InvokeString(string fn, string arg) {
        IntPtr mem = Marshal.StringToHGlobalAnsi(arg);
        try {
            AVS_Value a = new AVS_Value();
            a.type = (short)'s';
            a.array_size = 0;
            a.ptr = mem;
            return avs_invoke(env, fn, a, IntPtr.Zero);
        } finally {
            Marshal.FreeHGlobal(mem);
        }
    }

    public string Eval(string expr) {
        AVS_Value v = InvokeString("Eval", expr);
        try {
            switch ((char)v.type) {
                case 's': return Marshal.PtrToStringAnsi(v.ptr);
                case 'b': return (v.integer & 0xFF) != 0 ? "true" : "false";
                case 'i': return v.integer.ToString();
                case 'e': return "error: " + Marshal.PtrToStringAnsi(v.ptr);
                default: return "(type " + (char)v.type + ")";
            }
        } finally {
            avs_release_value(v);
        }
    }

    static void WaitUntil(long target) {
        long twoMs = Stopwatch.Frequency / 500;
        while (true) {
            long remaining = target - Stopwatch.GetTimestamp();
            if (remaining <= 0) return;
            if (remaining > twoMs) Thread.Sleep(1); else Thread.SpinWait(64);
        }
    }

    // paceFps <= 0: throughput mode. paceFps > 0: fixed-cadence (player-like) mode.
    public MaiRunResult Run(int total, int warmup, double paceFps) {
        double freq = Stopwatch.Frequency;
        long interval = paceFps > 0 ? (long)Math.Round(freq / paceFps) : 0;
        var lat = new double[total];
        var ft = new double[total];
        var late = new bool[total];
        long measureStart = 0, lastPresent = 0;

        MaiNative.timeBeginPeriod(1);
        try {
            long next = Stopwatch.GetTimestamp();
            long prevPresent = next;
            if (warmup == 0) measureStart = next;

            for (int i = 0; i < total; i++) {
                if (interval > 0) WaitUntil(next);
                long s = Stopwatch.GetTimestamp();
                IntPtr f = avs_get_frame(clip, i);
                long e = Stopwatch.GetTimestamp();

                IntPtr err = avs_clip_get_error(clip);
                if (f == IntPtr.Zero || err != IntPtr.Zero) {
                    string msg = err != IntPtr.Zero ? Marshal.PtrToStringAnsi(err) : "NULL frame";
                    if (f != IntPtr.Zero) avs_release_video_frame(f);
                    throw new Exception("avs_get_frame(" + i + ") failed: " + msg);
                }
                avs_release_video_frame(f);

                long present;
                if (interval > 0) {
                    long deadline = next + interval;
                    if (e > deadline) { late[i] = true; present = e; } else { present = deadline; }
                    next = present;
                } else {
                    present = e;
                }

                lat[i] = (e - s) * 1000.0 / freq;
                ft[i] = (present - prevPresent) * 1000.0 / freq;
                prevPresent = present;
                if (i == warmup - 1) measureStart = present;
                lastPresent = present;
            }
        } finally {
            MaiNative.timeEndPeriod(1);
        }

        int measured = total - warmup;
        var r = new MaiRunResult();
        r.Measured = measured;
        r.LatencyMs = new double[measured];
        r.FrameTimeMs = new double[measured];
        Array.Copy(lat, warmup, r.LatencyMs, 0, measured);
        Array.Copy(ft, warmup, r.FrameTimeMs, 0, measured);
        for (int i = warmup; i < total; i++) if (late[i]) r.Late++;
        r.ElapsedSec = (lastPresent - measureStart) / freq;
        return r;
    }

    public void Dispose() {
        if (clip != IntPtr.Zero) { avs_release_clip(clip); clip = IntPtr.Zero; }
        if (env != IntPtr.Zero) { avs_delete_script_environment(env); env = IntPtr.Zero; }
    }
}
'@

if (-not ('MaiAvsSession' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -Language CSharp
}

function Get-PeMachine([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    switch ([BitConverter]::ToUInt16($bytes, $peOffset + 4)) {
        0x8664 { return 'X64' }
        0xAA64 { return 'Arm64' }
        0x014C { return 'X86' }
        default { return 'Unknown' }
    }
}

function Format-Num([double]$Value, [int]$Digits = 2) {
    return $Value.ToString("F$Digits", $Inv)
}

# -----------------------------------------------------------------------------
# Worker mode: render one script in this (child) process and emit JSON
# -----------------------------------------------------------------------------
if ($WorkerMode) {
    $result = [ordered]@{ Ok = $false; Error = $null }
    try {
        $session = New-Object MaiAvsSession -ArgumentList $AviSynthDll, $WorkerScript
        try {
            $total = [Math]::Min($Frames + $WarmupFrames, $session.NumFrames)
            $warm = [Math]::Min($WarmupFrames, [Math]::Max(0, $total - 1))
            $sp = if ($StrictPrime) { 'true' } else { 'false' }

            $result.Workload = $session.Eval('MAI_Workload')
            $result.AvsVersion = $session.Eval('VersionString()')
            $result.DetectedMask = $session.Eval("FunctionExists(""GetPCoreMask"") ? GetPCoreMask($sp) : ""n/a""")
            $result.Width = $session.Width
            $result.Height = $session.Height
            $result.ClipFps = if ($session.FpsDen -gt 0) { $session.FpsNum / $session.FpsDen } else { 0 }

            $run = $session.Run($total, $warm, $WorkerPaceFps)
            $result.Measured = $run.Measured
            $result.Late = $run.Late
            $result.ElapsedSec = $run.ElapsedSec
            $result.LatencyMs = @($run.LatencyMs | ForEach-Object { [Math]::Round($_, 4) })
            $result.FrameTimeMs = @($run.FrameTimeMs | ForEach-Object { [Math]::Round($_, 4) })
            $result.Ok = $true
        } finally {
            $session.Dispose()
        }
    } catch {
        $result.Error = $_.Exception.Message
    }
    $result | ConvertTo-Json -Depth 3 -Compress | Set-Content -Path $WorkerResult -Encoding UTF8
    if ($result.Ok) { exit 0 } else { exit 1 }
}

# -----------------------------------------------------------------------------
# Controller mode
# -----------------------------------------------------------------------------
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$procArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
$archDir = if ($procArch -eq 'Arm64') { 'ARM64' } else { 'x64' }

if ([IntPtr]::Size -ne 8) { throw "A 64-bit PowerShell host is required." }

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " AvsAffinity Impact Measurement (PinWorkerThreads A/B)" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

# --- Resolve binaries ---
if (-not $AviSynthDll) { $AviSynthDll = Join-Path $env:SystemRoot 'System32\AviSynth.dll' }
if (-not (Test-Path $AviSynthDll)) { throw "AviSynth.dll not found at '$AviSynthDll'. Install AviSynth+ or pass -AviSynthDll." }
$AviSynthDll = (Resolve-Path $AviSynthDll).Path

if (-not $DllPath) { $DllPath = Join-Path $repoRoot "$archDir\Release\AvsAffinity.dll" }
if (-not (Test-Path $DllPath)) { throw "AvsAffinity.dll not found at '$DllPath'. Build the $archDir Release target or pass -DllPath." }
$DllPath = (Resolve-Path $DllPath).Path

if ($MvToolsDll) {
    if (-not (Test-Path $MvToolsDll)) { throw "mvtools2.dll not found at '$MvToolsDll'." }
    $MvToolsDll = (Resolve-Path $MvToolsDll).Path
}

foreach ($bin in @($AviSynthDll, $DllPath) + @($MvToolsDll | Where-Object { $_ })) {
    $m = Get-PeMachine $bin
    if ($m -ne $procArch) {
        throw "Architecture mismatch: '$bin' is $m but this PowerShell process is $procArch. Run a matching PowerShell host."
    }
}

# --- System / topology ---
$cpuName = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).ProcessorNameString
if (-not $cpuName) { $cpuName = $env:PROCESSOR_IDENTIFIER }
$cpuName = $cpuName.Trim()
$logical = [Environment]::ProcessorCount
if ($Threads -le 0) { $Threads = $logical }

$cores = [MaiTopology]::Cores()
$classes = @($cores | ForEach-Object { [int]$_[0] } | Sort-Object -Unique)
$topologyLines = foreach ($cls in ($classes | Sort-Object -Descending)) {
    # Note: PowerShell variables are case-insensitive; do not reuse the name of the -Mask parameter here.
    $group = @($cores | Where-Object { [int]$_[0] -eq $cls })
    $classMask = [uint64]0
    foreach ($c in $group) { $classMask = $classMask -bor [uint64]$c[1] }
    $lps = 0
    foreach ($c in $group) { $v = [uint64]$c[1]; while ($v -ne 0) { $lps += [int]($v -band 1); $v = $v -shr 1 } }
    "EfficiencyClass {0}: {1} cores / {2} logical processors (mask 0x{3:X})" -f $cls, $group.Count, $lps, $classMask
}
$isHybrid = $classes.Count -gt 1

$powerScheme = 'Unknown'
try {
    $pc = (& powercfg /getactivescheme) 2>$null | Out-String
    if ($pc -match '\(([^)]+)\)') { $powerScheme = $Matches[1] }
} catch { }
$powerSource = [MaiNative]::PowerSource()

Write-Host "[1/4] System" -ForegroundColor Yellow
Write-Host "  CPU:           $cpuName ($logical logical processors)" -ForegroundColor Gray
foreach ($line in $topologyLines) { Write-Host "  $line" -ForegroundColor Gray }
Write-Host "  Power:         $powerSource | Scheme: $powerScheme" -ForegroundColor Gray
Write-Host "  Host process:  $procArch" -ForegroundColor Gray
Write-Host "  AviSynth.dll:  $AviSynthDll" -ForegroundColor Gray
Write-Host "  AvsAffinity:   $DllPath" -ForegroundColor Gray

if (-not $isHybrid -and -not $Mask) {
    Write-Warning "All cores report the same EfficiencyClass. PinWorkerThreads() will be a no-op (mask 0x0), so both configurations should measure the same. Pass -Mask to force a core subset."
}

# --- Generate scripts ---
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $OutputMarkdown) { $OutputMarkdown = Join-Path $repoRoot "out\benchmarks\AffinityImpact-$stamp.md" }
$outDir = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputMarkdown))
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$workDir = Join-Path ([System.IO.Path]::GetTempPath()) "AvsAffinityBench-$stamp"
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

$fpsNum = [int][Math]::Round($TargetFps * 1000)
$fpsDen = 1000
$outFrames = $Frames + $WarmupFrames
$srcFrames = [int][Math]::Ceiling($outFrames * 24.0 / $TargetFps) + 8
$sp = if ($StrictPrime) { 'true' } else { 'false' }
$wantMv = if ($Workload -eq 'Builtin') { 'false' } else { 'true' }
$source = if ($SourceScript) { $SourceScript } else { 'ColorBarsHD(1920, 1080)' }
$mvLoad = if ($MvToolsDll) { "LoadPlugin(""$MvToolsDll"")" } else { '# mvtools2: autoload' }

$template = @'
# Generated by Measure-AffinityImpact.ps1 - configuration: {LABEL}
LoadPlugin("{AFFINITY}")
{MVLOAD}

function MaiMFlow(clip c, int srcFrames, int num, int den) {
    c = c.ConvertToYV12().AssumeFPS(24, 1).Trim(0, srcFrames - 1)
    super = MSuper(c, pel=2, hpad=16, vpad=16)
    bvec  = MAnalyse(super, isb=true,  blksize={BLKSIZE}, overlap={OVERLAP}, search=3)
    fvec  = MAnalyse(super, isb=false, blksize={BLKSIZE}, overlap={OVERLAP}, search=3)
    return MFlowFps(c, super, bvec, fvec, num=num, den=den)
}

function MaiBuiltin(clip c, int outFrames, int num, int den) {
    c = c.ConvertToYV12().AssumeFPS(num, den).Trim(0, outFrames - 1)
    return c.Spline64Resize(2880, 1620).Sharpen(0.5).Blur(0.5).Spline64Resize(1920, 1080)
}

src   = {SOURCE}
useMv = {WANTMV} && FunctionExists("MSuper")
global MAI_Workload = useMv ? "MFlowFps" : "Builtin"
last  = useMv ? MaiMFlow(src, {SRCFRAMES}, {NUM}, {DEN}) : MaiBuiltin(src, {OUTFRAMES}, {NUM}, {DEN})
last  = last.Trim(0, {OUTFRAMES} - 1)
{PIN}
Prefetch({THREADS})
'@

function New-BenchScript([string]$Label, [bool]$Pinned) {
    $pin = if ($Pinned) {
        "last  = PinWorkerThreads(last, mask=""$Mask"", strictPrime=$sp)"
    } else {
        '# PinWorkerThreads() omitted (baseline)'
    }
    $text = $template.
        Replace('{LABEL}', $Label).
        Replace('{AFFINITY}', $DllPath).
        Replace('{MVLOAD}', $mvLoad).
        Replace('{SOURCE}', $source).
        Replace('{WANTMV}', $wantMv).
        Replace('{SRCFRAMES}', [string]$srcFrames).
        Replace('{OUTFRAMES}', [string]$outFrames).
        Replace('{NUM}', [string]$fpsNum).
        Replace('{DEN}', [string]$fpsDen).
        Replace('{BLKSIZE}', [string]$BlockSize).
        Replace('{OVERLAP}', [string]([int]($BlockSize / 4))).
        Replace('{PIN}', $pin).
        Replace('{THREADS}', [string]$Threads)
    $path = Join-Path $workDir "$Label.avs"
    Set-Content -Path $path -Value $text -Encoding Ascii
    return $path
}

$scripts = @{
    Unpinned = New-BenchScript -Label 'Unpinned' -Pinned $false
    Pinned   = New-BenchScript -Label 'Pinned' -Pinned $true
}

# --- Statistics ---
function Get-Percentile([double[]]$Sorted, [double]$P) {
    if ($Sorted.Count -eq 0) { return 0.0 }
    $rank = [int][Math]::Ceiling($P / 100.0 * $Sorted.Count) - 1
    return $Sorted[[Math]::Max(0, [Math]::Min($Sorted.Count - 1, $rank))]
}

function Get-LowFps([double[]]$FrameTimes, [double]$Fraction) {
    $desc = @($FrameTimes | Sort-Object -Descending)
    $n = [Math]::Max(1, [int][Math]::Ceiling($desc.Count * $Fraction))
    $avg = ($desc[0..($n - 1)] | Measure-Object -Average).Average
    if ($avg -le 0) { return 0.0 }
    return 1000.0 / $avg
}

function Get-Median([double[]]$Values) {
    $s = @($Values | Sort-Object)
    if ($s.Count -eq 0) { return 0.0 }
    if ($s.Count % 2 -eq 1) { return $s[[int](($s.Count - 1) / 2)] }
    return ($s[$s.Count / 2 - 1] + $s[$s.Count / 2]) / 2.0
}

function Get-RunStats($Raw) {
    $lat = [double[]]@($Raw.LatencyMs | Sort-Object)
    $ft = [double[]]@($Raw.FrameTimeMs)
    $ftMean = ($ft | Measure-Object -Average).Average
    $ftVar = ($ft | ForEach-Object { ($_ - $ftMean) * ($_ - $ftMean) } | Measure-Object -Average).Average
    [PSCustomObject]@{
        AvgFps     = if ($Raw.ElapsedSec -gt 0) { $Raw.Measured / $Raw.ElapsedSec } else { 0.0 }
        Low1Fps    = Get-LowFps $ft 0.01
        Low01Fps   = Get-LowFps $ft 0.001
        FtStdMs    = [Math]::Sqrt($ftVar)
        LatP50Ms   = Get-Percentile $lat 50
        LatP99Ms   = Get-Percentile $lat 99
        LatMaxMs   = $lat[$lat.Count - 1]
        Late       = [int]$Raw.Late
        LatePct    = if ($Raw.Measured -gt 0) { 100.0 * $Raw.Late / $Raw.Measured } else { 0.0 }
    }
}

# --- Run trials ---
$modes = switch ($Mode) { 'Both' { @('Paced', 'Throughput') } default { @($Mode) } }
$hostExe = (Get-Process -Id $PID).Path
$runs = New-Object System.Collections.Generic.List[object]
$meta = $null

Write-Host "`n[2/4] Configuration" -ForegroundColor Yellow
Write-Host "  Modes: $($modes -join ', ') | Target: $(Format-Num $TargetFps) fps | Frames: $Frames (+$WarmupFrames warmup) | Trials: $Trials" -ForegroundColor Gray
Write-Host "  Prefetch threads: $Threads | Background load threads: $BackgroundLoad | Mask: $(if ($Mask) { $Mask } else { 'auto' }) | strictPrime: $sp" -ForegroundColor Gray

Write-Host "`n[3/4] Running" -ForegroundColor Yellow
if ($BackgroundLoad -gt 0) { [MaiLoad]::Start($BackgroundLoad) }
try {
    $runIndex = 0
    $runTotal = $modes.Count * $Trials * 2
    foreach ($m in $modes) {
        $pace = if ($m -eq 'Paced') { $TargetFps } else { 0 }
        for ($t = 1; $t -le $Trials; $t++) {
            $order = if ($t % 2 -eq 1) { @('Unpinned', 'Pinned') } else { @('Pinned', 'Unpinned') }
            foreach ($cfg in $order) {
                $runIndex++
                if ($runIndex -gt 1 -and $CooldownSeconds -gt 0) { Start-Sleep -Seconds $CooldownSeconds }
                Write-Host ("  [{0}/{1}] {2,-10} trial {3}  {4,-8} ... " -f $runIndex, $runTotal, $m, $t, $cfg) -NoNewline

                $resultPath = Join-Path $workDir ("{0}-{1}-{2}.json" -f $m, $t, $cfg)
                $childArgs = @(
                    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath,
                    '-WorkerMode', '-WorkerScript', $scripts[$cfg], '-WorkerResult', $resultPath,
                    '-AviSynthDll', $AviSynthDll, '-Frames', $Frames, '-WarmupFrames', $WarmupFrames,
                    '-WorkerPaceFps', $pace.ToString($Inv)
                )
                if ($StrictPrime) { $childArgs += '-StrictPrime' }
                & $hostExe @childArgs | Out-Null

                if (-not (Test-Path $resultPath)) { throw "Worker produced no result file (exit code $LASTEXITCODE)." }
                $raw = Get-Content $resultPath -Raw | ConvertFrom-Json
                if (-not $raw.Ok) { throw "Worker failed: $($raw.Error)" }
                if (-not $meta) { $meta = $raw }

                $stats = Get-RunStats $raw
                $runs.Add([PSCustomObject]@{ Mode = $m; Trial = $t; Config = $cfg; Stats = $stats; Raw = $raw })
                Write-Host ("Avg {0} fps | 1% Low {1} fps | p99 {2} ms | Late {3}" -f (Format-Num $stats.AvgFps), (Format-Num $stats.Low1Fps), (Format-Num $stats.LatP99Ms), $stats.Late) -ForegroundColor Green
            }
        }
    }
} finally {
    if ($BackgroundLoad -gt 0) { [MaiLoad]::Stop() }
}

# --- Report ---
Write-Host "`n[4/4] Report" -ForegroundColor Yellow

$metrics = @(
    @{ Key = 'AvgFps';   Label = 'Avg FPS';            Kind = 'fps';   Higher = $true;  Digits = 2; Modes = @('Paced', 'Throughput') },
    @{ Key = 'Low1Fps';  Label = '1% Low FPS';         Kind = 'fps';   Higher = $true;  Digits = 2; Modes = @('Paced') },
    @{ Key = 'Low01Fps'; Label = '0.1% Low FPS';       Kind = 'fps';   Higher = $true;  Digits = 2; Modes = @('Paced') },
    @{ Key = 'Late';     Label = 'Late Frames';        Kind = 'count'; Higher = $false; Digits = 1; Modes = @('Paced') },
    @{ Key = 'LatePct';  Label = 'Late Frames (%)';    Kind = 'count'; Higher = $false; Digits = 2; Modes = @('Paced') },
    @{ Key = 'FtStdMs';  Label = 'Frame Time SD (ms)'; Kind = 'ms';    Higher = $false; Digits = 3; Modes = @('Paced') },
    @{ Key = 'LatP50Ms'; Label = 'p50 Latency (ms)';   Kind = 'ms';    Higher = $false; Digits = 2; Modes = @('Paced') },
    @{ Key = 'LatP99Ms'; Label = 'p99 Latency (ms)';   Kind = 'ms';    Higher = $false; Digits = 2; Modes = @('Paced') },
    @{ Key = 'LatMaxMs'; Label = 'Max Latency (ms)';   Kind = 'ms';    Higher = $false; Digits = 2; Modes = @('Paced') }
)

function Format-Change($Metric, [double]$U, [double]$P) {
    $d = $P - $U
    switch ($Metric.Kind) {
        'fps' {
            if ($U -eq 0 -or [Math]::Abs($d / $U) -lt 0.0005) { return @('0.0%', 'same') }
            $pct = 100.0 * $d / $U
            $text = '{0}{1}%' -f $(if ($pct -gt 0) { '+' } else { '' }), (Format-Num $pct 1)
        }
        'ms' {
            if ([Math]::Abs($d) -lt 0.005) { return @('0.00 ms', 'same') }
            $text = '{0}{1} ms' -f $(if ($d -gt 0) { '+' } else { '' }), (Format-Num $d 2)
        }
        default {
            if ([Math]::Abs($d) -lt 0.005) { return @('0', 'same') }
            $text = '{0}{1}' -f $(if ($d -gt 0) { '+' } else { '' }), (Format-Num $d $Metric.Digits)
        }
    }
    $better = if ($Metric.Higher) { $d -gt 0 } else { $d -lt 0 }
    return @($text, $(if ($better) { 'better' } else { 'worse' }))
}

$md = New-Object System.Collections.Generic.List[string]
$md.Add("# AvsAffinity Impact Report")
$md.Add("")
$md.Add("## System")
$md.Add("")
$md.Add("* **CPU:** $cpuName ($logical logical processors)")
foreach ($line in $topologyLines) { $md.Add("* **Topology:** $line") }
$md.Add("* **Detected P-core mask (GetPCoreMask):** ``$($meta.DetectedMask)``$(if ($Mask) { " (overridden with ``$Mask``)" })")
$md.Add("* **Power:** $powerSource, scheme ``$powerScheme``")
$md.Add("* **AviSynth+:** $($meta.AvsVersion) ($procArch)")
$md.Add("")
$md.Add("## Configuration")
$md.Add("")
$md.Add("* **Workload:** $($meta.Workload), $($meta.Width)x$($meta.Height) output at $(Format-Num $TargetFps) fps")
$md.Add("* **Source:** ``$source``")
$md.Add("* **Prefetch threads:** $Threads")
$md.Add("* **Background load:** $BackgroundLoad busy-loop threads at normal priority")
$md.Add("* **Frames per run:** $Frames measured + $WarmupFrames warmup; $Trials alternating trial pairs per mode; $CooldownSeconds s cooldown")
$md.Add("* **Values:** median across trials")
$md.Add("")

$summaryRows = @()
foreach ($m in $modes) {
    $md.Add("## $m Mode")
    $md.Add("")
    if ($m -eq 'Paced') {
        $md.Add("Frames requested at a fixed $(Format-Num $TargetFps) fps cadence. A frame is late if it completes after its presentation deadline. Frame time is the effective presentation interval.")
    } else {
        $md.Add("Frames requested back-to-back with no pacing. Pinning restricts the worker pool to a subset of cores, so lower Avg FPS is expected in this mode.")
    }
    $md.Add("")
    $md.Add("| Metric | Unpinned | Pinned | Change | Pinned vs. Unpinned |")
    $md.Add("| :--- | ---: | ---: | ---: | :---: |")
    foreach ($metric in ($metrics | Where-Object { $_.Modes -contains $m })) {
        $u = Get-Median ([double[]]@($runs | Where-Object { $_.Mode -eq $m -and $_.Config -eq 'Unpinned' } | ForEach-Object { $_.Stats.($metric.Key) }))
        $p = Get-Median ([double[]]@($runs | Where-Object { $_.Mode -eq $m -and $_.Config -eq 'Pinned' } | ForEach-Object { $_.Stats.($metric.Key) }))
        $change = Format-Change $metric $u $p
        $md.Add("| $($metric.Label) | $(Format-Num $u $metric.Digits) | $(Format-Num $p $metric.Digits) | $($change[0]) | $($change[1]) |")
        $summaryRows += [PSCustomObject]@{ Mode = $m; Metric = $metric.Label; Unpinned = (Format-Num $u $metric.Digits); Pinned = (Format-Num $p $metric.Digits); Change = $change[0]; Result = $change[1] }
    }
    $md.Add("")
    $md.Add("<details><summary>Per-trial results</summary>")
    $md.Add("")
    if ($m -eq 'Paced') {
        $md.Add("| Trial | Config | Avg FPS | 1% Low FPS | 0.1% Low FPS | p99 Latency (ms) | Late Frames |")
        $md.Add("| ---: | :--- | ---: | ---: | ---: | ---: | ---: |")
    } else {
        $md.Add("| Trial | Config | Avg FPS | Elapsed (s) |")
        $md.Add("| ---: | :--- | ---: | ---: |")
    }
    foreach ($r in ($runs | Where-Object { $_.Mode -eq $m })) {
        $s = $r.Stats
        if ($m -eq 'Paced') {
            $md.Add("| $($r.Trial) | $($r.Config) | $(Format-Num $s.AvgFps) | $(Format-Num $s.Low1Fps) | $(Format-Num $s.Low01Fps) | $(Format-Num $s.LatP99Ms) | $($s.Late) |")
        } else {
            $md.Add("| $($r.Trial) | $($r.Config) | $(Format-Num $s.AvgFps) | $(Format-Num $r.Raw.ElapsedSec) |")
        }
    }
    $md.Add("")
    $md.Add("</details>")
    $md.Add("")
}

# Calibration hint: paced results are uninformative when the workload has excessive headroom.
$calibrationNote = $null
$tpUnpinned = @($runs | Where-Object { $_.Mode -eq 'Throughput' -and $_.Config -eq 'Unpinned' })
if ($tpUnpinned.Count -gt 0) {
    $tpFps = Get-Median ([double[]]@($tpUnpinned | ForEach-Object { $_.Stats.AvgFps }))
    $ratio = $tpFps / $TargetFps
    if ($ratio -gt 2.0) {
        $calibrationNote = "Unpinned throughput is $(Format-Num $ratio 1)x the $(Format-Num $TargetFps) fps target. Paced mode has enough headroom to hide scheduling effects; increase the workload (-BlockSize 8, a real -SourceScript, or -BackgroundLoad) until this ratio is about 1.2x-1.6x."
    } elseif ($ratio -lt 1.0) {
        $calibrationNote = "Unpinned throughput is below the $(Format-Num $TargetFps) fps target ($(Format-Num $ratio 2)x). Paced mode will be capacity-bound in both configurations; reduce the workload (-BlockSize 32) or -TargetFps."
    }
}
if ($calibrationNote) {
    $md.Add("> [!NOTE]")
    $md.Add("> $calibrationNote")
    $md.Add("")
}

$md.Add("*Generated by ``scripts/Measure-AffinityImpact.ps1`` on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss').*")
[System.IO.File]::WriteAllLines($OutputMarkdown, $md)

$jsonPath = [System.IO.Path]::ChangeExtension($OutputMarkdown, '.json')
$runs | ForEach-Object {
    [PSCustomObject]@{
        Mode = $_.Mode; Trial = $_.Trial; Config = $_.Config; Stats = $_.Stats
        LatencyMs = $_.Raw.LatencyMs; FrameTimeMs = $_.Raw.FrameTimeMs
    }
} | ConvertTo-Json -Depth 4 -Compress | Set-Content -Path $jsonPath -Encoding UTF8

if ($KeepScripts) {
    Copy-Item $scripts['Unpinned'], $scripts['Pinned'] -Destination $outDir -Force
}
Remove-Item -Recurse -Force $workDir -ErrorAction SilentlyContinue

$summaryRows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host "[+] Markdown report: $OutputMarkdown" -ForegroundColor Cyan
Write-Host "[+] Raw frame data:  $jsonPath" -ForegroundColor Cyan
