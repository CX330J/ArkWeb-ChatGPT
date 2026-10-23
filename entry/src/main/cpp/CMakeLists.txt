cmake_minimum_required(VERSION 3.5.0)
project(bowen_web)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

include_directories(${NATIVERENDER_ROOT_PATH}
                    ${NATIVERENDER_ROOT_PATH}/include)

# ArkTS imports this bridge as libmihomo.so.
add_library(mihomo SHARED napi_init.cpp)

# 链接 OHOS 运行库
target_link_libraries(mihomo PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
)

# ---------------------------------------------------------------------------
# 关于 libmihomo_core.so（Go c-shared 内核）
#
# 【故意不在这里 add_library IMPORTED 去链接它】
# 原因：我们的 NAPI 层是运行时 dlopen("libmihomo_core.so") + dlsym 取符号，
# 而不是编译期绑定。这样做的两个实际好处：
#   1) 内核缺失/加载失败时，应用仍能正常启动，只在调用代理功能时报错，
#      而不是整包在动态链接阶段就起不来；
#   2) 换内核版本只需要替换 libs/arm64-v8a/libmihomo_core.so，不必重编 C++。
#
# libmihomo_core.so 由 hvigor 从 entry/libs/arm64-v8a/ 自动打包进 HAP，
# 运行时落在 <bundleCodeDir>/libs/arm64-v8a/ 下（见 napi_init.cpp 的路径拼接）。
# ---------------------------------------------------------------------------
