cmake_minimum_required(VERSION 3.22.1)

project(splitvpn_native)

add_library(tunfdexec SHARED tunfdexec.cpp)

target_link_libraries(tunfdexec log)

# Rust core (packages/vpn-core), staged by scripts/build-core.sh.
set(SPLITVPN_CORE_LIB ${CMAKE_CURRENT_SOURCE_DIR}/prebuilt/${ANDROID_ABI}/libsplitvpn_core.a)
if(NOT EXISTS ${SPLITVPN_CORE_LIB})
    message(FATAL_ERROR "Missing ${SPLITVPN_CORE_LIB}; run apps/android/scripts/build-core.sh first.")
endif()
add_library(splitvpn_core STATIC IMPORTED)
set_target_properties(splitvpn_core PROPERTIES IMPORTED_LOCATION ${SPLITVPN_CORE_LIB})

add_library(splitvpncore SHARED core_jni.cpp)
target_include_directories(splitvpncore PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/../../../../../../packages/vpn-core/include)
target_link_libraries(splitvpncore splitvpn_core log dl m)
