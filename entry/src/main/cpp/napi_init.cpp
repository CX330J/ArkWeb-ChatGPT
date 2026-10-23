/*
 * Mihomo 内核的 NAPI 桥接层。
 *
 * ===========================================================================
 * 内核来源与设计说明
 * ===========================================================================
 *
 * 本工程的内核 libmihomo_core.so 是**我们自己交叉编译的标准 mihomo**，
 * 而不是网上现成的 SSRVPN 版本。原因：
 *   · SSRVPN 版内核导出的 SsrvpnInit 期望 TUN 文件描述符（配合 VpnExtensionAbility
 *     接管全机流量），把配置文件路径传进去会直接导致应用闪退（真机实测）；
 *   · 我们要的是"只代理本应用"：本地 SOCKS5 入站 + ArkWeb 的 applyProxyOverride，
 *     不需要任何 VPN 权限。
 *
 * 编译方式（详见 tools/mihomo/build-ohos.ps1）：
 *   华为 ohos Go 工具链 go1.24.5.ohosv1r1（官方 Go 不支持 openharmony）
 *   GOOS=openharmony GOARCH=arm64 CGO_ENABLED=1
 *   入口 tools/mihomo/cshared_main.go 导出 Mihomo* 函数
 *
 * 关键校验：产物 TLS 重定位必须是 R_AARCH64_TLSDESC
 * （旧工具链会产出 IE-TLS，OHOS 的 musl loader 拒绝加载，报 dlopen 失败）。
 *
 * ===========================================================================
 * 运行时加载约定
 * ===========================================================================
 * 1) 用**裸库名** dlopen（不能传绝对路径）：OHOS 有动态链接命名空间隔离，
 *    对 bundle 内 .so 用绝对路径会报 "check ns accessible failed"。
 * 2) 全部 dlsym 运行时绑定，不在编译期链接内核 —— 内核缺失时应用照常启动。
 * 3) 所有导出函数都做了结构化返回，失败信息可读，不让错误静默消失。
 */

#include <string>
#include <dlfcn.h>
#include <atomic>
#include <chrono>
#include <memory>

#include "napi/native_api.h"
#include <hilog/log.h>

#undef LOG_DOMAIN
#undef LOG_TAG
#define LOG_DOMAIN 0x3200
#define LOG_TAG "MihomoBridge"

// 内核导出的 C ABI（与 cshared_main.go 一一对应）
using FnInit = int (*)(const char *configPath);
using FnNoArgInt = int (*)();
using FnStr = char *(*)();
using FnFree = void (*)(char *);
using FnNormalize = char *(*)(const char *);

namespace {

struct CoreHandle {
    void *handle = nullptr;
    FnInit fnInit = nullptr;
    FnNoArgInt fnStart = nullptr;
    FnNoArgInt fnStop = nullptr;
    FnNoArgInt fnIsRunning = nullptr;
    FnStr fnVersion = nullptr;
    FnStr fnLastError = nullptr;
    FnFree fnFree = nullptr;
    FnNormalize fnNormalize = nullptr;
    std::string loadError;
    std::string libPath;
};

CoreHandle g_core;
std::atomic<bool> g_startPending{false};
std::atomic<bool> g_stopRequested{false};

bool GetStringArg(napi_env env, napi_value value, std::string &out) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &len) != napi_ok || len == 0) {
        return false;
    }
    out.resize(len + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, value, &out[0], len + 1, &copied) != napi_ok) {
        return false;
    }
    out.resize(copied);
    return true;
}

napi_value MakeString(napi_env env, const std::string &s) {
    napi_value v = nullptr;
    napi_create_string_utf8(env, s.c_str(), s.size(), &v);
    return v;
}

struct ResultBuilder {
    napi_env env;
    napi_value obj;
    explicit ResultBuilder(napi_env e) : env(e) {
        napi_create_object(env, &obj);
    }
    void SetBool(const char *k, bool v) {
        napi_value n = nullptr;
        napi_get_boolean(env, v, &n);
        napi_set_named_property(env, obj, k, n);
    }
    void SetInt(const char *k, int32_t v) {
        napi_value n = nullptr;
        napi_create_int32(env, v, &n);
        napi_set_named_property(env, obj, k, n);
    }
    void SetStr(const char *k, const std::string &v) {
        napi_set_named_property(env, obj, k, MakeString(env, v));
    }
    napi_value Value() const { return obj; }
};

/**
 * 读取内核返回的字符串并立即释放。
 * 内核每次调用都返回新分配的 CString（见 cshared_main.go 的 C.CString），
 * 不释放会持续泄漏，所以这里统一 Take 走。
 */
std::string TakeString(FnStr fn, FnFree freeFn) {
    if (fn == nullptr) {
        return std::string();
    }
    char *p = fn();
    if (p == nullptr) {
        return std::string();
    }
    std::string s(p);
    if (freeFn != nullptr) {
        freeFn(p);
    }
    return s;
}

/**
 * 加载内核。
 *
 * ===========================================================================
 * SAFE_PATHS 必须在 dlopen 之前设置（踩坑记录）
 * ===========================================================================
 * mihomo 的 constant/path.go 里，safePaths 是在**包初始化阶段**一次性读取的：
 *
 *     var defaultPath = initDefaultPath()
 *     func initDefaultPath() *path {
 *         for _, safePath := range filepath.SplitList(os.Getenv("SAFE_PATHS")) { ... }
 *     }
 *
 * Go 的包级变量初始化和 init() 都在 dlopen 时执行完成。
 * 所以如果在 MihomoInit 里才 setenv，已经太晚 —— 内核读到的还是空值，
 * 校验依旧失败，报 "path is not subpath of home directory or SAFE_PATHS"。
 *
 * 结论：**必须在 dlopen 之前 setenv**。这就是本函数要先拿到 appDir 再加载的原因。
 */
napi_value LoadCore(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    ResultBuilder r(env);
    if (g_core.handle != nullptr) {
        r.SetBool("ok", true);
        r.SetStr("path", g_core.libPath);
        r.SetStr("version", TakeString(g_core.fnVersion, g_core.fnFree));
        r.SetStr("note", std::string("already_loaded"));
        return r.Value();
    }

    std::string dir;
    if (!GetStringArg(env, args[0], dir)) {
        r.SetBool("ok", false);
        r.SetStr("error", std::string("缺少 bundleCodeDir 参数"));
        return r.Value();
    }
    (void)dir;

    // 【关键】在 dlopen 之前设置 SAFE_PATHS。
    // args[1] 是应用私有目录（filesDir）；内核要把规则集缓存写到那下面。
    std::string safeDir;
    if (argc >= 2 && GetStringArg(env, args[1], safeDir) && safeDir.length() > 0) {
        setenv("SAFE_PATHS", safeDir.c_str(), 1);
        // HOME 也给上：mihomo 的 homeDir 逻辑优先用 HOME，
        // 部分路径校验会回退到 home 判断，一并设置可减少边界情况。
        setenv("HOME", safeDir.c_str(), 1);
        OH_LOG_INFO(LOG_APP, "pre-dlopen SAFE_PATHS=%{public}s", safeDir.c_str());
    } else {
        OH_LOG_WARN(LOG_APP, "LoadCore 未收到 safeDir，规则集路径校验可能失败");
    }

    // 裸库名加载：见文件头"运行时加载约定"第 1 条
    const char *libName = "libmihomo_core.so";
    g_core.libPath = libName;

    void *h = dlopen(libName, RTLD_NOW | RTLD_LOCAL);
    if (h == nullptr) {
        const char *e = dlerror();
        g_core.loadError = e ? std::string(e) : std::string("dlopen 返回 nullptr");
        OH_LOG_ERROR(LOG_APP, "dlopen(%{public}s) failed: %{public}s", libName, g_core.loadError.c_str());
        r.SetBool("ok", false);
        r.SetStr("path", libName);
        r.SetStr("error", g_core.loadError);
        return r.Value();
    }

    g_core.handle = h;
    g_core.fnInit = reinterpret_cast<FnInit>(dlsym(h, "MihomoInit"));
    g_core.fnStart = reinterpret_cast<FnNoArgInt>(dlsym(h, "MihomoStart"));
    g_core.fnStop = reinterpret_cast<FnNoArgInt>(dlsym(h, "MihomoStop"));
    g_core.fnIsRunning = reinterpret_cast<FnNoArgInt>(dlsym(h, "MihomoIsRunning"));
    g_core.fnVersion = reinterpret_cast<FnStr>(dlsym(h, "MihomoVersion"));
    g_core.fnLastError = reinterpret_cast<FnStr>(dlsym(h, "MihomoLastError"));
    g_core.fnFree = reinterpret_cast<FnFree>(dlsym(h, "MihomoFree"));
    g_core.fnNormalize = reinterpret_cast<FnNormalize>(dlsym(h, "MihomoNormalizeSubscription"));

    bool hasCore = (g_core.fnInit != nullptr) && (g_core.fnStart != nullptr) &&
                   (g_core.fnStop != nullptr);

    std::string version = TakeString(g_core.fnVersion, g_core.fnFree);
    OH_LOG_INFO(LOG_APP, "dlopen ok path=%{public}s version=%{public}s hasCore=%{public}d",
                libName, version.c_str(), static_cast<int>(hasCore));

    r.SetBool("ok", hasCore);
    r.SetStr("path", libName);
    r.SetStr("version", version);
    r.SetInt("symbols", (g_core.fnInit ? 1 : 0) + (g_core.fnStart ? 1 : 0) + (g_core.fnStop ? 1 : 0) +
                        (g_core.fnIsRunning ? 1 : 0) + (g_core.fnVersion ? 1 : 0) +
                        (g_core.fnLastError ? 1 : 0) + (g_core.fnFree ? 1 : 0));
    if (!hasCore) {
        r.SetStr("error", std::string("dlopen 成功但缺少关键符号 MihomoInit/MihomoStart/MihomoStop"));
    }
    return r.Value();
}

struct StartWork {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    std::string configPath;
    std::string error;
    int ret = -1;
    bool stopped = false;
};

// This callback runs on a worker thread. No NAPI values may be accessed here.
void ExecuteStart(napi_env, void *data) {
    auto *startup = static_cast<StartWork *>(data);
    const auto began = std::chrono::steady_clock::now();
    if (!g_stopRequested.load()) {
        startup->ret = g_core.fnInit(startup->configPath.c_str());
        if (startup->ret == 0 && !g_stopRequested.load()) {
            startup->ret = g_core.fnStart();
        }
        startup->error = TakeString(g_core.fnLastError, g_core.fnFree);
    }
    if (g_stopRequested.load()) {
        g_core.fnStop();
        startup->ret = -1;
        startup->error = "代理启动已取消";
        startup->stopped = true;
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now() - began).count();
    OH_LOG_INFO(LOG_APP, "Mihomo startup worker ret=%{public}d durationMs=%{public}lld",
                startup->ret, static_cast<long long>(elapsed));
}

void CompleteStart(napi_env env, napi_status status, void *data) {
    std::unique_ptr<StartWork> startup(static_cast<StartWork *>(data));
    // A stop can arrive after ExecuteStart finishes but before this callback runs.
    if (status != napi_ok) {
        startup->ret = -1;
        startup->error = "代理启动任务未完成";
    } else if (g_stopRequested.load() && !startup->stopped) {
        napi_delete_async_work(env, startup->work);
        startup->work = nullptr;
        napi_value resource = MakeString(env, "MihomoStartupCancel");
        napi_status queued = napi_create_async_work(env, nullptr, resource,
            ExecuteStart, CompleteStart, startup.get(), &startup->work);
        if (queued == napi_ok) { queued = napi_queue_async_work(env, startup->work); }
        if (queued == napi_ok) {
            startup.release();
            return;
        }
        startup->ret = -1;
        startup->error = "无法调度代理启动取消任务";
    }
    g_startPending.store(false);
    ResultBuilder result(env);
    result.SetBool("ok", startup->ret == 0);
    result.SetInt("ret", startup->ret);
    result.SetStr("lastError", startup->error);
    napi_resolve_deferred(env, startup->deferred, result.Value());
    if (startup->work != nullptr) { napi_delete_async_work(env, startup->work); }
}

/** Parse and start on the worker pool; resolve the result on the JS thread. */
napi_value CoreStart(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    auto startup = std::make_unique<StartWork>();
    napi_value promise = nullptr;
    if (napi_create_promise(env, &startup->deferred, &promise) != napi_ok) {
        napi_throw_error(env, nullptr, "无法创建代理启动 Promise");
        return nullptr;
    }
    std::string error;
    if (g_core.handle == nullptr || g_core.fnInit == nullptr || g_core.fnStart == nullptr) {
        error = "内核未加载";
    } else if (argc == 0 || !GetStringArg(env, args[0], startup->configPath)) {
        error = "缺少配置文件路径";
    } else if (g_startPending.exchange(true)) {
        error = "代理内核正在启动";
    } else {
        g_stopRequested.store(false);
        napi_value resource = MakeString(env, "MihomoStartup");
        napi_status queued = napi_create_async_work(env, nullptr, resource,
            ExecuteStart, CompleteStart, startup.get(), &startup->work);
        if (queued == napi_ok) {
            queued = napi_queue_async_work(env, startup->work);
        }
        if (queued == napi_ok) {
            startup.release();
            return promise;
        }
        if (startup->work != nullptr) { napi_delete_async_work(env, startup->work); }
        g_startPending.store(false);
        error = "无法调度代理启动任务";
    }
    ResultBuilder result(env);
    result.SetBool("ok", false);
    result.SetStr("error", error);
    napi_resolve_deferred(env, startup->deferred, result.Value());
    return promise;
}

/** 停止内核。 */
napi_value CoreStop(napi_env env, napi_callback_info info) {
    (void)info;
    ResultBuilder r(env);
    if (g_startPending.load()) {
        g_stopRequested.store(true);
        r.SetBool("ok", true);
        return r.Value();
    }
    if (g_core.handle == nullptr || g_core.fnStop == nullptr) {
        r.SetBool("ok", false);
        r.SetStr("error", std::string("内核未加载"));
        return r.Value();
    }
    int ret = g_core.fnStop();
    OH_LOG_INFO(LOG_APP, "MihomoStop ret=%{public}d", ret);
    r.SetBool("ok", ret == 0);
    r.SetInt("ret", ret);
    return r.Value();
}

/** 查询运行状态。 */
napi_value CoreStatus(napi_env env, napi_callback_info info) {
    (void)info;
    ResultBuilder r(env);
    if (g_core.handle == nullptr) {
        r.SetBool("ok", false);
        r.SetStr("error", std::string("内核未加载"));
        return r.Value();
    }
    int running = g_core.fnIsRunning ? g_core.fnIsRunning() : -1;
    r.SetBool("ok", true);
    r.SetInt("running", running);
    r.SetStr("version", TakeString(g_core.fnVersion, g_core.fnFree));
    r.SetStr("lastError", TakeString(g_core.fnLastError, g_core.fnFree));
    r.SetStr("path", g_core.libPath);
    return r.Value();
}

napi_value NormalizeSubscription(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string input;
    if (g_core.fnNormalize == nullptr || argc == 0 || !GetStringArg(env, args[0], input)) {
        return MakeString(env, "{\"ok\":false,\"error\":\"订阅解析内核未就绪\",\"providers\":[]}");
    }
    char *output = g_core.fnNormalize(input.c_str());
    std::string result = output ? output : "{\"ok\":false,\"error\":\"订阅解析失败\",\"providers\":[]}";
    if (output && g_core.fnFree) { g_core.fnFree(output); }
    return MakeString(env, result);
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadCore", nullptr, LoadCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreStart", nullptr, CoreStart, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreStop", nullptr, CoreStop, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"coreStatus", nullptr, CoreStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"normalizeSubscription", nullptr, NormalizeSubscription, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module g_mihomoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "mihomo",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterMihomoModule(void) {
    napi_module_register(&g_mihomoModule);
}
