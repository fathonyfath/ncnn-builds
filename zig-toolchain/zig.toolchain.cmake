# Use Zig as the C/C++ toolchain.
# Target comes from $ZIG_TARGET (default x86_64-linux-gnu.2.17); Zig binary from $ZIG (default: zig on PATH).
set(ZIG_TARGET "$ENV{ZIG_TARGET}")
if(NOT ZIG_TARGET)
    set(ZIG_TARGET "x86_64-linux-gnu.2.17")
endif()

# CPU arch is the first component of the triple (x86_64, aarch64, ...)
string(REGEX MATCH "^[^-]+" CMAKE_SYSTEM_PROCESSOR "${ZIG_TARGET}")

if(ZIG_TARGET MATCHES "-windows")
    set(CMAKE_SYSTEM_NAME Windows)
elseif(ZIG_TARGET MATCHES "-macos")
    set(CMAKE_SYSTEM_NAME Darwin)
else()
    set(CMAKE_SYSTEM_NAME Linux)
endif()

set(CMAKE_C_COMPILER   ${CMAKE_CURRENT_LIST_DIR}/zig-cc)
set(CMAKE_CXX_COMPILER ${CMAKE_CURRENT_LIST_DIR}/zig-c++)
set(CMAKE_AR           ${CMAKE_CURRENT_LIST_DIR}/zig-ar)
set(CMAKE_RANLIB       ${CMAKE_CURRENT_LIST_DIR}/zig-ranlib)
