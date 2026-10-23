/**
 * Mihomo 代理内核的 ArkTS 封装。
 *
 * ===========================================================================
 * 方案说明
 * ===========================================================================
 * 目标：**只给本应用（ArkWeb 里的 ChatGPT 网页）加速**，不影响手机其它应用，
 *       因此不需要 VPN 权限、不需要 TUN、不接管全局流量。
 *
 * 实现链路：
 *   1) 内核（自编译标准 mihomo）在本地监听 127.0.0.1:<mixed-port>（socks5 + http）
 *   2) ArkWeb 通过 insertProxyRule + applyProxyOverride 让**本应用的 Web 组件**走这个代理
 *   3) 内核按订阅里的规则/VLESS+REALITY 等协议出站
 *
 * 内核是自编译的 libmihomo_core.so（不是网上现成的 SSRVPN TUN 版），
 * 构建脚本与导出接口见 tools/mihomo/。
 */

import mihomoNative from 'libmihomo.so';

export interface CoreLoadResult {
  ok: boolean;
  path: string;
  version: string;
  symbols?: number;
  note?: string;
  error?: string;
}

export interface CoreOpResult {
  ok: boolean;
  ret?: number;
  lastError?: string;
  error?: string;
}

export interface CoreStatusResult {
  ok: boolean;
  running?: number;
  version?: string;
  lastError?: string;
  path?: string;
  error?: string;
}

interface MihomoNativeApi {
  loadCore(bundleCodeDir: string, safeDir: string): CoreLoadResult;
  coreStart(configPath: string): Promise<CoreOpResult>;
  coreStop(): CoreOpResult;
  coreStatus(): CoreStatusResult;
  normalizeSubscription(input: string): string;
}

const native: MihomoNativeApi = mihomoNative as MihomoNativeApi;

/** 代理内核的单例控制器。 */
export class MihomoCore {
  static normalizeSubscription(input: string): string {
    return native.normalizeSubscription(input);
  }
  private static loaded: boolean = false;
  private static loadResult: CoreLoadResult | null = null;

  /**
   * 幂等加载内核（dlopen + dlsym）。
   *
   * safeDir 会作为 SAFE_PATHS 传给 C 层，且**必须在 dlopen 之前设置**：
   * mihomo 的 safePaths 是 Go 包初始化时读取的，dlopen 即完成初始化，
   * 之后再设环境变量无效（实测验证过）。
   */
  static load(bundleCodeDir: string, safeDir: string): CoreLoadResult {
    if (MihomoCore.loaded && MihomoCore.loadResult !== null) {
      return MihomoCore.loadResult;
    }
    let result: CoreLoadResult;
    try {
      result = native.loadCore(bundleCodeDir, safeDir);
    } catch (err) {
      result = { ok: false, path: '', version: '', error: 'NAPI 异常: ' + MihomoCore.errText(err) };
    }
    MihomoCore.loaded = result.ok;
    MihomoCore.loadResult = result;
    return result;
  }

  /** 在后台解析配置并启动监听，避免规则初始化阻塞界面线程。 */
  static async start(configPath: string): Promise<CoreOpResult> {
    try {
      return await native.coreStart(configPath);
    } catch (err) {
      return { ok: false, error: 'NAPI 异常: ' + MihomoCore.errText(err) };
    }
  }

  /** 停止监听。 */
  static stop(): CoreOpResult {
    try {
      return native.coreStop();
    } catch (err) {
      return { ok: false, error: 'NAPI 异常: ' + MihomoCore.errText(err) };
    }
  }

  /** 查询状态。 */
  static status(): CoreStatusResult {
    try {
      return native.coreStatus();
    } catch (err) {
      return { ok: false, error: 'NAPI 异常: ' + MihomoCore.errText(err) };
    }
  }

  static isAvailable(): boolean {
    return MihomoCore.loaded;
  }

  private static errText(err: Object | null | undefined): string {
    if (err instanceof Error) {
      return err.message;
    }
    return JSON.stringify(err);
  }
}
