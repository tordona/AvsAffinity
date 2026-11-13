#ifndef VERSION_H
#define VERSION_H

#define FILEVERSION_VAL 1,1,0,0
#define FILEVERSION_BASE_STR "1.1.0.0"

#if defined(_M_ARM64) || defined(_ARM64_) || defined(__aarch64__) || defined(__arm64__)
    #define ARCH_SUFFIX "-arm64"
#elif defined(_M_AMD64) || defined(_M_X64) || defined(_AMD64_) || defined(__x86_64__) || defined(__amd64__) || defined(__x86_64) || defined(_WIN64)
    #define ARCH_SUFFIX "-x64"
#else
    #define ARCH_SUFFIX ""
#endif

#define FILEVERSION_STR FILEVERSION_BASE_STR ARCH_SUFFIX
#define PRODUCTVERSION_STR FILEVERSION_BASE_STR ARCH_SUFFIX

#endif // VERSION_H
