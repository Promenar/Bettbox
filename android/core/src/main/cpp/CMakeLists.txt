cmake_minimum_required(VERSION 3.22.1)

project("core")

message("CMAKE_SOURCE_DIR ${CMAKE_SOURCE_DIR}")

message("CMAKE_BUILD_TYPE ${CMAKE_BUILD_TYPE}")

if (NOT "${CMAKE_BUILD_TYPE}" STREQUAL "Debug")
    add_compile_options(-O3)

    add_compile_options(-flto)

    add_compile_options(-g0)

    add_compile_options(-ffunction-sections -fdata-sections)

    add_compile_options(-fno-exceptions -fno-rtti)

    add_link_options(
            -flto
            -Wl,--gc-sections
            -Wl,--strip-all
            -Wl,--exclude-libs=ALL
    )

    if (${ANDROID_ABI} STREQUAL "arm64-v8a" OR ${ANDROID_ABI} STREQUAL "x86_64")
        add_link_options(-Wl,-z,max-page-size=16384)
    endif()

    add_compile_options(-fvisibility=hidden -fvisibility-inlines-hidden)
endif ()

set(LIB_CLASH_DIR "${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")
set(LIB_CLASH_PATH "${LIB_CLASH_DIR}/libclash.so")
set(LIB_CLASH_HEADER_PATH "${LIB_CLASH_DIR}/libclash.h")

# 每个 ABI 必须同时具备核心与生成头文件，禁止产出缺少核心功能的 JNI 库。
foreach(REQUIRED_CORE_FILE IN ITEMS "${LIB_CLASH_PATH}" "${LIB_CLASH_HEADER_PATH}")
    if (NOT EXISTS "${REQUIRED_CORE_FILE}" OR IS_DIRECTORY "${REQUIRED_CORE_FILE}")
        message(FATAL_ERROR "ABI ${ANDROID_ABI} 缺少必要核心文件：${REQUIRED_CORE_FILE}。请先生成对应 ABI 的核心。")
    endif ()
endforeach()

add_compile_definitions(LIBCLASH)
include_directories("${LIB_CLASH_DIR}")
add_library(clash SHARED IMPORTED)
# Go 核心没有 SONAME，必须按库名链接，避免将本机绝对路径写入 DT_NEEDED。
set_target_properties(clash PROPERTIES
        IMPORTED_LOCATION "${LIB_CLASH_PATH}"
        IMPORTED_NO_SONAME TRUE)
add_library(${CMAKE_PROJECT_NAME} SHARED
        jni_helper.cpp
        config_jni.cpp
        core.cpp)
target_link_libraries(${CMAKE_PROJECT_NAME} clash)
