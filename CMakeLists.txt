cmake_minimum_required(VERSION 3.15)
project(AvsAffinity LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(SOURCES
    src/AvsAffinity.cpp
)

if(WIN32)
    list(APPEND SOURCES src/AvsAffinity.rc)
endif()

add_library(AvsAffinity SHARED
    ${SOURCES}
)

target_include_directories(AvsAffinity PRIVATE
    include
    include/avs
)

if(MSVC)
    target_compile_options(AvsAffinity PRIVATE /W3 /O2)
    # Link C runtime statically in Release
    set_property(TARGET AvsAffinity PROPERTY
        MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:DebugDLL>")
else()
    target_compile_options(AvsAffinity PRIVATE -Wall -O3)
endif()

set_target_properties(AvsAffinity PROPERTIES
    PREFIX ""
    OUTPUT_NAME "AvsAffinity"
)
