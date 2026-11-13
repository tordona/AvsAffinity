# ==============================================================================
# Test-AvsAffinity.ps1 - Automated Verification Harness for AvsAffinity
# ==============================================================================
param(
    [string]$DllPath = "",
    [string]$AviSynthDll = "",
    [switch]$SkipRuntime,
    [switch]$VerboseOutput
)

$ErrorActionPreference = "Stop"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " AvsAffinity Automated Test & Verification Suite" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

# Pre-flight: Verify AviSynth.dll prerequisite unless -SkipRuntime is explicitly set
$resolvedAvsDll = $null
if (-not $SkipRuntime) {
    $avsCandidates = @(
        $AviSynthDll,
        (Join-Path $env:SystemRoot "System32\AviSynth.dll"),
        (Get-Command "AviSynth.dll" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ) | Where-Object { $_ }

    $resolvedAvsDll = $avsCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $resolvedAvsDll) {
        Write-Host "[FAIL] Core prerequisite AviSynth.dll was not found." -ForegroundColor Red
        Write-Host "Checked locations:" -ForegroundColor Gray
        $avsCandidates | ForEach-Object { Write-Host "  - $_" -ForegroundColor Gray }
        throw "AviSynth.dll is required for runtime verification. Pass -AviSynthDll <path> or use -SkipRuntime."
    }
    $resolvedAvsDll = (Resolve-Path $resolvedAvsDll).Path
    Write-Host "[Pre-flight] AviSynth.dll found: $resolvedAvsDll`n" -ForegroundColor Green
}

# Step 1: Detect CPU Architecture and Core Topology independently
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class CpuTopologyHelper {
    public const int RelationProcessorCore = 0;
    public const int ERROR_INSUFFICIENT_BUFFER = 122;

    [StructLayout(LayoutKind.Sequential)]
    public struct GROUP_AFFINITY {
        public UIntPtr Mask;
        public ushort Group;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 3)]
        public ushort[] Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESSOR_RELATIONSHIP {
        public byte Flags;
        public byte EfficiencyClass;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 20)]
        public byte[] Reserved;
        public ushort GroupCount;
        public GROUP_AFFINITY GroupMask; // GroupMask[0]
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX {
        public int Relationship;
        public int Size;
        public PROCESSOR_RELATIONSHIP Processor;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetLogicalProcessorInformationEx(
        int relationshipType,
        IntPtr buffer,
        ref uint returnedLength);

    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationThread(
        IntPtr threadHandle,
        int threadInformationClass,
        ref THREAD_BASIC_INFORMATION threadInformation,
        int threadInformationLength,
        out int returnLength);

    [StructLayout(LayoutKind.Sequential)]
    public struct THREAD_BASIC_INFORMATION {
        public int ExitStatus;
        public IntPtr TebBaseAddress;
        public IntPtr UniqueProcessId;
        public IntPtr UniqueThreadId;
        public UIntPtr AffinityMask;
        public int Priority;
        public int BasePriority;
    }

    public static Dictionary<string, ulong> GetCalculatedTopology() {
        var result = new Dictionary<string, ulong>();
        uint length = 0;
        GetLogicalProcessorInformationEx(RelationProcessorCore, IntPtr.Zero, ref length);
        if (length == 0) return result;

        IntPtr ptr = Marshal.AllocHGlobal((int)length);
        try {
            if (!GetLogicalProcessorInformationEx(RelationProcessorCore, ptr, ref length)) {
                return result;
            }

            byte minClass = 255;
            byte maxClass = 0;
            int offset = 0;

            // Pass 1: find spread
            while (offset < length) {
                var item = (SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX)Marshal.PtrToStructure(
                    new IntPtr(ptr.ToInt64() + offset), typeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX));

                if (item.Relationship == RelationProcessorCore) {
                    byte eff = item.Processor.EfficiencyClass;
                    if (eff < minClass) minClass = eff;
                    if (eff > maxClass) maxClass = eff;
                }
                offset += item.Size;
            }

            result["MinClass"] = (ulong)minClass;
            result["MaxClass"] = (ulong)maxClass;

            ulong pCoreMask = 0;
            ulong primeMask = 0;

            if (minClass < maxClass) {
                offset = 0;
                while (offset < length) {
                    var item = (SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX)Marshal.PtrToStructure(
                        new IntPtr(ptr.ToInt64() + offset), typeof(SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX));

                    if (item.Relationship == RelationProcessorCore) {
                        byte eff = item.Processor.EfficiencyClass;
                        if (eff > minClass) {
                            pCoreMask |= (ulong)item.Processor.GroupMask.Mask;
                        }
                        if (eff == maxClass) {
                            primeMask |= (ulong)item.Processor.GroupMask.Mask;
                        }
                    }
                    offset += item.Size;
                }
            }

            result["PCoreMask"] = pCoreMask;
            result["PrimeMask"] = primeMask;
            return result;
        } finally {
            Marshal.FreeHGlobal(ptr);
        }
    }

    public static List<string> GetPeExports(byte[] pe) {
        var exports = new List<string>();
        int peOffset = BitConverter.ToInt32(pe, 0x3C);
        ushort numSections = BitConverter.ToUInt16(pe, peOffset + 6);
        ushort optHeaderSize = BitConverter.ToUInt16(pe, peOffset + 20);
        int optHeaderOffset = peOffset + 24;
        ushort magic = BitConverter.ToUInt16(pe, optHeaderOffset);
        int dataDirOffset = (magic == 0x20B) ? optHeaderOffset + 112 : optHeaderOffset + 96;
        uint exportRva = BitConverter.ToUInt32(pe, dataDirOffset);
        uint exportSize = BitConverter.ToUInt32(pe, dataDirOffset + 4);
        if (exportRva == 0 || exportSize == 0) return exports;

        int sectionsOffset = optHeaderOffset + optHeaderSize;
        Func<uint, int> rvaToOffset = (uint rva) => {
            for (int i = 0; i < numSections; i++) {
                int sec = sectionsOffset + i * 40;
                uint vAddr = BitConverter.ToUInt32(pe, sec + 12);
                uint vSize = BitConverter.ToUInt32(pe, sec + 8);
                uint rawSize = BitConverter.ToUInt32(pe, sec + 16);
                uint rawPtr = BitConverter.ToUInt32(pe, sec + 20);
                uint span = Math.Max(vSize, rawSize);
                if (rva >= vAddr && rva < vAddr + span) {
                    return (int)(rawPtr + (rva - vAddr));
                }
            }
            return -1;
        };

        int expOff = rvaToOffset(exportRva);
        if (expOff < 0) return exports;

        uint numNames = BitConverter.ToUInt32(pe, expOff + 24);
        uint namesRva = BitConverter.ToUInt32(pe, expOff + 32);
        int namesOff = rvaToOffset(namesRva);
        if (namesOff < 0) return exports;

        for (uint i = 0; i < numNames; i++) {
            uint nameRva = BitConverter.ToUInt32(pe, namesOff + (int)(i * 4));
            int nameOff = rvaToOffset(nameRva);
            if (nameOff < 0) continue;
            int end = nameOff;
            while (end < pe.Length && pe[end] != 0) end++;
            exports.Add(System.Text.Encoding.ASCII.GetString(pe, nameOff, end - nameOff));
        }
        return exports;
    }
}
"@

Write-Host "[1/4] Probing Physical Processor Topology..." -ForegroundColor Cyan
$topo = [CpuTopologyHelper]::GetCalculatedTopology()

$minEff = $topo["MinClass"]
$maxEff = $topo["MaxClass"]
$pMask  = $topo["PCoreMask"]
$primeMask = $topo["PrimeMask"]

Write-Host "  -> Efficiency Class Range: min=$minEff, max=$maxEff" -ForegroundColor Gray

if ($minEff -eq $maxEff) {
    Write-Host "  -> Topology Classification: Homogeneous (All cores identical)" -ForegroundColor Green
    Write-Host "  -> Expected Filter Behavior: Safe No-Op (affinity unconstrained, mask = 0x0)" -ForegroundColor Green
} else {
    Write-Host "  -> Topology Classification: Heterogeneous (Hybrid P/E Architecture Detected)" -ForegroundColor Yellow
    Write-Host ("  -> Expected P-Core Bitmask:  0x{0:X}" -f $pMask) -ForegroundColor Green
    if ($maxEff -gt ($minEff + 1)) {
        Write-Host ("  -> Expected Prime Core Mask: 0x{0:X}" -f $primeMask) -ForegroundColor Cyan
    }
}

# Step 2: Locate Compiled AvsAffinity.dll
Write-Host "`n[2/4] Verifying AvsAffinity.dll Binary Artifacts..." -ForegroundColor Cyan

$searchPaths = @(
    $DllPath,
    "$PSScriptRoot\..\x64\Release\AvsAffinity.dll",
    "$PSScriptRoot\..\ARM64\Release\AvsAffinity.dll",
    "$PSScriptRoot\..\build\Release\AvsAffinity.dll"
) | Where-Object { $_ }

$candidates = @($searchPaths | Where-Object { Test-Path $_ })

if ($candidates.Count -eq 0) {
    Write-Host "  [FAIL] AvsAffinity.dll binary not found." -ForegroundColor Red
    Write-Host "  Checked paths:" -ForegroundColor Gray
    $searchPaths | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    throw "AvsAffinity.dll not found. Build the project before running tests."
}

$resolvedDll = (Resolve-Path $candidates[0]).Path
Write-Host "  -> Found Binary: $resolvedDll" -ForegroundColor Green

# Inspect binary architecture via PE header
$bytes = [System.IO.File]::ReadAllBytes($resolvedDll)
$peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
$machine = [BitConverter]::ToUInt16($bytes, $peOffset + 4)

$archStr = switch ($machine) {
    0x8664 { "x86-64 (AMD64)" }
    0xAA64 { "ARM64 (AArch64)" }
    0x014C { "x86 (32-bit)" }
    Default { "Unknown (0x{0:X4})" -f $machine }
}
Write-Host "  -> PE Machine Architecture: $archStr" -ForegroundColor Green

# Step 3: Verify PE Export Table
Write-Host "`n[3/4] Inspecting PE Export Table..." -ForegroundColor Cyan

$exports = [CpuTopologyHelper]::GetPeExports($bytes)
if ($exports -contains "AvisynthPluginInit3") {
    Write-Host "  [PASS] Confirmed PE export: AvisynthPluginInit3" -ForegroundColor Green
} else {
    throw "AvisynthPluginInit3 not found in PE export table of $resolvedDll"
}

# Step 4: Runtime AviSynth+ Execution Test
Write-Host "`n[4/4] Running AviSynth+ Runtime Verification..." -ForegroundColor Cyan

if ($SkipRuntime) {
    Write-Host "  [SKIP] Runtime verification skipped (-SkipRuntime specified)." -ForegroundColor Yellow
} else {
    $procArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    $archMatch = (($machine -eq 0x8664 -and $procArch -eq "X64") -or ($machine -eq 0xAA64 -and $procArch -eq "Arm64"))
    if (-not $archMatch) {
        throw "Binary architecture ($archStr) does not match host process ($procArch). Run under matching PowerShell architecture or pass -SkipRuntime."
    }

    $escapedDll = $resolvedDll.Replace('\', '\\')
    $runtimeScript = @"
LoadPlugin("$escapedDll")
mask = GetPCoreMask()
ColorBars(640, 360)
PinWorkerThreads(debug=true)
Prefetch(4, 4)
Subtitle(mask)
"@
    $tempAvs = Join-Path $env:TEMP "avsaffinity_test_$([guid]::NewGuid().ToString('N')).avs"
    [System.IO.File]::WriteAllText($tempAvs, $runtimeScript, [System.Text.Encoding]::ASCII)

    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class AvsRuntimeTest {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr LoadLibrary(string lpFileName);

    [StructLayout(LayoutKind.Sequential)]
    public struct AVS_Value {
        public short type;
        public short array_size;
        public IntPtr d;
    }

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern IntPtr avs_create_script_environment(int version);

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern void avs_delete_script_environment(IntPtr env);

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall, CharSet = CharSet.Ansi)]
    public static extern AVS_Value avs_invoke(IntPtr env, string name, AVS_Value args, IntPtr arg_names);

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern IntPtr avs_take_clip(AVS_Value val, IntPtr env);

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern void avs_release_clip(IntPtr clip);

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern void avs_release_value(AVS_Value val);

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern IntPtr avs_get_frame(IntPtr clip, int n);

    [DllImport("AviSynth.dll", CallingConvention = CallingConvention.StdCall)]
    public static extern void avs_release_video_frame(IntPtr frame);

    public static void Run(string avsDllPath, string scriptPath) {
        if (LoadLibrary(avsDllPath) == IntPtr.Zero) {
            throw new Exception("Failed to load AviSynth.dll from " + avsDllPath + " (Win32 error " + Marshal.GetLastWin32Error() + ")");
        }
        IntPtr env = avs_create_script_environment(6);
        if (env == IntPtr.Zero) throw new Exception("avs_create_script_environment returned null.");
        try {
            IntPtr pathPtr = Marshal.StringToHGlobalAnsi(scriptPath);
            try {
                var arg = new AVS_Value { type = (short)'s', array_size = 0, d = pathPtr };
                AVS_Value res = avs_invoke(env, "Import", arg, IntPtr.Zero);
                if (res.type == (short)'e') {
                    string err = Marshal.PtrToStringAnsi(res.d);
                    avs_release_value(res);
                    throw new Exception("AviSynth Import failed: " + err);
                }
                IntPtr clip = avs_take_clip(res, env);
                avs_release_value(res);
                try {
                    for (int i = 0; i < 16; i++) {
                        IntPtr frame = avs_get_frame(clip, i);
                        if (frame == IntPtr.Zero) throw new Exception("avs_get_frame returned null at frame " + i);
                        avs_release_video_frame(frame);
                    }
                } finally {
                    avs_release_clip(clip);
                }
            } finally {
                Marshal.FreeHGlobal(pathPtr);
            }
        } finally {
            avs_delete_script_environment(env);
        }
    }
}
"@
        [AvsRuntimeTest]::Run($resolvedAvsDll, $tempAvs)
        Write-Host "  [PASS] Runtime AviSynth+ script execution (16 frames with Prefetch) succeeded." -ForegroundColor Green
    } finally {
        if (Test-Path $tempAvs) { Remove-Item -Force $tempAvs }
    }
}

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host " Test Suite Result: PASS" -ForegroundColor Green
Write-Host " All AvsAffinity checks passed." -ForegroundColor Green
Write-Host "================================================================`n" -ForegroundColor Cyan
