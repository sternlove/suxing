cmake_minimum_required(VERSION 3.5.0)
project(llamaohos)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NATIVE_ROOT ${CMAKE_CURRENT_SOURCE_DIR})
set(LIBS_DIR ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a)

include_directories(
    ${NATIVE_ROOT}/include
    ${NATIVE_ROOT}/include/ggml
)

# llama.cpp 预编译产物（AArch64，SONAME 已去版本号），直接复用，不重编
set(PREBUILT_LLAMA     ${LIBS_DIR}/libllama.so)
set(PREBUILT_GGML      ${LIBS_DIR}/libggml.so)
set(PREBUILT_GGML_BASE ${LIBS_DIR}/libggml-base.so)
set(PREBUILT_GGML_CPU  ${LIBS_DIR}/libggml-cpu.so)

add_library(llamaohos SHARED napi_init.cpp)

target_compile_options(llamaohos PRIVATE -Wall -Wextra)

target_link_directories(llamaohos PRIVATE ${LIBS_DIR})

target_link_libraries(llamaohos PUBLIC
    ${PREBUILT_LLAMA}
    ${PREBUILT_GGML}
    ${PREBUILT_GGML_BASE}
    ${PREBUILT_GGML_CPU}
    libace_napi.z.so
    hilog_ndk.z
)

