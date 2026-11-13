#include <windows.h>
#include <vector>
#include <string>
#include <unordered_map>
#include <shared_mutex>
#include <cstdio>
#include <cstdint>
#include <cerrno>
#include <cstdlib>
#include "avisynth.h"

// ============================================================================
// Topology Detection Helpers
// ============================================================================

static DWORD_PTR DetectPCoreMask(bool strictPrime, bool debug) {
    DWORD length = 0;
    GetLogicalProcessorInformationEx(RelationProcessorCore, nullptr, &length);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || length == 0) {
        if (debug) {
            OutputDebugStringA("[AvsAffinity] ERROR: Failed to query processor information buffer length.\n");
        }
        return 0;
    }

    std::vector<BYTE> buffer(length);
    PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX info =
        reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(buffer.data());

    if (!GetLogicalProcessorInformationEx(RelationProcessorCore, info, &length)) {
        if (debug) {
            OutputDebugStringA("[AvsAffinity] ERROR: Failed to retrieve logical processor information.\n");
        }
        return 0;
    }

    BYTE minClass = 255;
    BYTE maxClass = 0;

    // Pass 1: Identify topology spread (EfficiencyClass distribution)
    BYTE* ptr = buffer.data();
    while (ptr < buffer.data() + length) {
        PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX item =
            reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(ptr);
        if (item->Size == 0) break;

        if (item->Relationship == RelationProcessorCore) {
            BYTE eff = item->Processor.EfficiencyClass;
            if (eff < minClass) minClass = eff;
            if (eff > maxClass) maxClass = eff;
        }
        ptr += item->Size;
    }

    // Homogeneous CPU (e.g. Intel N100, AMD Ryzen standard, Snapdragon X Elite):
    // All cores have identical efficiency class; nothing to isolate.
    if (minClass == maxClass) {
        if (debug) {
            char dbg[256];
            snprintf(dbg, sizeof(dbg), "[AvsAffinity] Homogeneous CPU detected (class=%u). Affinity pinning bypassed.\n", minClass);
            OutputDebugStringA(dbg);
        }
        return 0;
    }

    // Pass 2: Aggregate affinity bitmask (Processor Group 0 only for SetThreadAffinityMask)
    DWORD_PTR pCoreMask = 0;
    ptr = buffer.data();
    while (ptr < buffer.data() + length) {
        PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX item =
            reinterpret_cast<PSYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX>(ptr);
        if (item->Size == 0) break;

        if (item->Relationship == RelationProcessorCore &&
            item->Processor.GroupCount > 0 &&
            item->Processor.GroupMask[0].Group == 0) {
            BYTE eff = item->Processor.EfficiencyClass;
            // strictPrime=true: isolate only highest tier (e.g. Cortex-X1 on Snapdragon 8cx Gen 3)
            // strictPrime=false: isolate all performance tiers above the efficiency baseline
            bool select = strictPrime ? (eff == maxClass) : (eff > minClass);
            if (select) {
                pCoreMask |= item->Processor.GroupMask[0].Mask;
            }
        }
        ptr += item->Size;
    }

    if (debug) {
        char dbg[256];
        snprintf(dbg, sizeof(dbg), "[AvsAffinity] Heterogeneous CPU detected (minClass=%u, maxClass=%u). P-core mask: 0x%llX\n",
                 minClass, maxClass, static_cast<unsigned long long>(pCoreMask));
        OutputDebugStringA(dbg);
    }

    return pCoreMask;
}

static DWORD_PTR ParseAffinityMask(const char* maskStr, bool debug = false) {
    if (!maskStr || *maskStr == '\0') return 0;
    errno = 0;
    char* endptr = nullptr;
    unsigned long long val = _strtoui64(maskStr, &endptr, 0);
    if (errno == ERANGE || endptr == maskStr || *endptr != '\0') {
        if (debug) {
            char dbg[256];
            snprintf(dbg, sizeof(dbg), "[AvsAffinity] WARNING: Invalid affinity mask '%s'. Pinning disabled.\n", maskStr);
            OutputDebugStringA(dbg);
        }
        return 0;
    }
    return static_cast<DWORD_PTR>(val);
}

// ============================================================================
// Clip Filter: PinWorkerThreads
// ============================================================================

class PinWorkerThreads : public GenericVideoFilter {
    struct PinnedThread {
        HANDLE hThread;
        DWORD_PTR prevMask;
    };

    DWORD_PTR m_pCoreMask;
    bool m_debug;
    mutable std::shared_mutex m_mutex;
    std::unordered_map<DWORD, PinnedThread> m_pinnedThreads;

public:
    PinWorkerThreads(PClip child, DWORD_PTR mask, bool debug)
        : GenericVideoFilter(child), m_pCoreMask(mask), m_debug(debug) {}

    ~PinWorkerThreads() override {
        std::unique_lock<std::shared_mutex> lock(m_mutex);
        for (auto& kv : m_pinnedThreads) {
            if (kv.second.hThread != nullptr) {
                if (kv.second.prevMask != 0) {
                    SetThreadAffinityMask(kv.second.hThread, kv.second.prevMask);
                }
                CloseHandle(kv.second.hThread);
            }
        }
        m_pinnedThreads.clear();
    }

    int __stdcall SetCacheHints(int cachehints, int frame_range) override {
        return cachehints == CACHE_GET_MTMODE ? MT_NICE_FILTER : 0;
    }

    PVideoFrame __stdcall GetFrame(int n, IScriptEnvironment* env) override {
        if (m_pCoreMask != 0) {
            DWORD tid = GetCurrentThreadId();
            bool alreadyTracked = false;
            {
                std::shared_lock<std::shared_mutex> rlock(m_mutex);
                alreadyTracked = (m_pinnedThreads.find(tid) != m_pinnedThreads.end());
            }

            if (!alreadyTracked) {
                std::unique_lock<std::shared_mutex> wlock(m_mutex);
                if (m_pinnedThreads.find(tid) == m_pinnedThreads.end()) {
                    HANDLE hCurrent = GetCurrentThread();
                    DWORD_PTR prevMask = SetThreadAffinityMask(hCurrent, m_pCoreMask);

                    if (prevMask == 0) {
                        if (m_debug) {
                            char dbg[256];
                            snprintf(dbg, sizeof(dbg), "[AvsAffinity] ERROR: SetThreadAffinityMask failed for thread %lu (err=%lu, mask=0x%llX)\n",
                                     tid, GetLastError(), static_cast<unsigned long long>(m_pCoreMask));
                            OutputDebugStringA(dbg);
                        }
                        m_pinnedThreads.emplace(tid, PinnedThread{ nullptr, 0 });
                    } else {
                        HANDLE hDup = nullptr;
                        if (!DuplicateHandle(GetCurrentProcess(), hCurrent, GetCurrentProcess(), &hDup,
                                             THREAD_SET_INFORMATION | THREAD_QUERY_INFORMATION, FALSE, 0)) {
                            hDup = nullptr;
                        }
                        m_pinnedThreads.emplace(tid, PinnedThread{ hDup, prevMask });

                        if (m_debug) {
                            char dbg[256];
                            snprintf(dbg, sizeof(dbg), "[AvsAffinity] Thread %lu pinned to mask 0x%llX (previous: 0x%llX)\n",
                                     tid, static_cast<unsigned long long>(m_pCoreMask), static_cast<unsigned long long>(prevMask));
                            OutputDebugStringA(dbg);
                        }
                    }
                }
            }
        }

        return child->GetFrame(n, env);
    }
};

// ============================================================================
// AviSynth Factory Functions
// ============================================================================

AVSValue __cdecl Create_PinWorkerThreads(AVSValue args, void*, IScriptEnvironment* env) {
    PClip child = args[0].AsClip();
    bool debug = args[3].AsBool(false);
    DWORD_PTR mask = 0;

    if (args[1].IsString() && args[1].AsString()[0] != '\0') {
        mask = ParseAffinityMask(args[1].AsString(), debug);
        if (debug) {
            char dbg[256];
            snprintf(dbg, sizeof(dbg), "[AvsAffinity] Manual mask specified: 0x%llX\n",
                     static_cast<unsigned long long>(mask));
            OutputDebugStringA(dbg);
        }
    } else {
        bool strictPrime = args[2].AsBool(false);
        mask = DetectPCoreMask(strictPrime, debug);
    }

    return new PinWorkerThreads(child, mask, debug);
}

// Introspection: returns the detected P-core mask as a hex string
AVSValue __cdecl Create_GetPCoreMask(AVSValue args, void*, IScriptEnvironment* env) {
    bool strictPrime = args[0].AsBool(false);
    DWORD_PTR mask = DetectPCoreMask(strictPrime, false);

    char buf[32];
    snprintf(buf, sizeof(buf), "0x%llX", static_cast<unsigned long long>(mask));
    return env->SaveString(buf);
}

// Process-wide affinity setter for CLI / encoder pipelines
AVSValue __cdecl Create_SetProcessAffinity(AVSValue args, void*, IScriptEnvironment* env) {
    DWORD_PTR mask = 0;
    if (args[0].IsString() && args[0].AsString()[0] != '\0') {
        mask = ParseAffinityMask(args[0].AsString());
    } else {
        bool strictPrime = args[1].AsBool(false);
        mask = DetectPCoreMask(strictPrime, false);
    }

    if (mask == 0) return AVSValue(false);
    return AVSValue(SetProcessAffinityMask(GetCurrentProcess(), mask) != 0);
}

// ============================================================================
// Plugin Entry Point
// ============================================================================

const AVS_Linkage* AVS_linkage = nullptr;

extern "C" __declspec(dllexport) const char* __stdcall
AvisynthPluginInit3(IScriptEnvironment* env, const AVS_Linkage* const vectors) {
    AVS_linkage = vectors;
    env->AddFunction("PinWorkerThreads", "c[mask]s[strictPrime]b[debug]b", Create_PinWorkerThreads, 0);
    env->AddFunction("GetPCoreMask", "[strictPrime]b", Create_GetPCoreMask, 0);
    env->AddFunction("SetProcessAffinity", "[mask]s[strictPrime]b", Create_SetProcessAffinity, 0);
    return "AvsAffinity: Thread-level CPU Performance Core Affinity Filter";
}
