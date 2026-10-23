// mihomo 的 c-shared 入口：把 mihomo 内核包装成可以被 NAPI dlopen 的库。
//
// 与现成的 SSRVPN 内核的根本区别：
//   · SSRVPN 版本面向 TUN（Init 接受 tun fd），必须走 VpnExtensionAbility 全局接管流量；
//   · 本版本面向**本地 SOCKS/HTTP 入站**，只监听 127.0.0.1，
//     配合 ArkWeb 的 insertProxyRule + applyProxyOverride 实现"只代理本应用"。
//
// 导出接口（C ABI）：
//   MihomoInit(const char* configPath)  加载配置，不启动
//   MihomoStart()                        启动内核（开始监听 mixed-port）
//   MihomoStop()                         停止
//   MihomoIsRunning()                    1=运行中 0=未运行
//   MihomoVersion()                      返回版本字符串
//   MihomoLastError()                    最近一次错误（无错误返回空串）
//
// 设计要点：
//   1) 所有导出函数都**不 panic 到 C 侧**：用 recover 包住，避免 Go panic 直接杀掉宿主进程；
//   2) Init/Start 分离：先确保配置解析成功再启动，失败时宿主能拿到明确错误；
//   3) 错误信息用全局变量保存，通过 MihomoLastError 读取。

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"fmt"
	"sync"
	"unsafe"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/hub/executor"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/log"
)

const coreVersion = "ohos-mihomo-socks"

var (
	mu                sync.Mutex
	running           bool
	lastError         string
	curConfig         *config.Config
	controllerStarted bool
)

// setErr 记录最近一次错误（线程安全）。
func setErr(err error) {
	mu.Lock()
	defer mu.Unlock()
	if err == nil {
		lastError = ""
	} else {
		lastError = err.Error()
		log.Warnln("mihomo error: %s", err.Error())
	}
}

func getErr() string {
	mu.Lock()
	defer mu.Unlock()
	return lastError
}

// MihomoInit 解析并应用配置（不启动监听）。
//
//export MihomoInit
func MihomoInit(cfgPath *C.char) (ret C.int) {
	// recover 兜底：Go panic 若跨过 CGO 边界会直接终止宿主进程，
	// 这里把它转成返回码 + 错误字符串。
	defer func() {
		if r := recover(); r != nil {
			setErr(fmt.Errorf("panic in Init: %v", r))
			ret = -2
		}
	}()

	if cfgPath == nil {
		setErr(errors.New("config path is nil"))
		return -1
	}
	path := C.GoString(cfgPath)

	cfg, err := executor.ParseWithPath(path)
	if err != nil {
		setErr(fmt.Errorf("parse config failed: %w", err))
		return -1
	}

	mu.Lock()
	curConfig = cfg
	mu.Unlock()

	setErr(nil)
	return 0
}

// MihomoStart 启动内核，开始监听配置里的 mixed-port / socks-port。
//
//export MihomoStart
func MihomoStart() (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			setErr(fmt.Errorf("panic in Start: %v", r))
			ret = -2
		}
	}()

	mu.Lock()
	cfg := curConfig
	isRunning := running
	mu.Unlock()

	if isRunning {
		return 0 // 幂等
	}
	if cfg == nil {
		setErr(errors.New("not initialized, call MihomoInit first"))
		return -1
	}

	// executor.ApplyConfig 会真正建立 listeners（含 mixed-port 的 socks+http）。
	// 它内部是异步启动各 listener，返回即代表已下发。
	executor.ApplyConfig(cfg, true)
	// 控制器在进程内复用，避免快速重启时异步监听的关闭/创建相互覆盖。
	if !controllerStarted {
		route.SetEmbedMode(true)
		route.ReCreateServer(&route.Config{
			Addr:   cfg.Controller.ExternalController,
			Secret: cfg.Controller.Secret,
		})
		controllerStarted = true
	}

	mu.Lock()
	running = true
	mu.Unlock()

	setErr(nil)
	log.Infoln("mihomo started (ohos socks mode)")
	return 0
}

// MihomoStop 停止内核。
//
//export MihomoStop
func MihomoStop() (ret C.int) {
	defer func() {
		if r := recover(); r != nil {
			setErr(fmt.Errorf("panic in Stop: %v", r))
			ret = -2
		}
	}()

	mu.Lock()
	wasRunning := running
	running = false
	mu.Unlock()

	if !wasRunning {
		return 0
	}
	// executor.Shutdown 关闭所有 listener 与连接
	executor.Shutdown()
	setErr(nil)
	log.Infoln("mihomo stopped")
	return 0
}

// MihomoIsRunning 返回 1 表示运行中。
//
//export MihomoIsRunning
func MihomoIsRunning() C.int {
	mu.Lock()
	defer mu.Unlock()
	if running {
		return 1
	}
	return 0
}

// MihomoVersion 返回版本字符串（由宿主负责不释放：指向静态内存）。
//
//export MihomoVersion
func MihomoVersion() *C.char {
	return C.CString(coreVersion)
}

// MihomoLastError 返回最近一次错误。
//
//export MihomoLastError
func MihomoLastError() *C.char {
	s := getErr()
	if s == "" {
		// 返回空串而不是 nil，避免宿主侧判空遗漏
		return C.CString("")
	}
	return C.CString(s)
}

// MihomoFree 释放由本库 CString 分配的内存（宿主拿到字符串后调用）。
//
//export MihomoFree
func MihomoFree(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

//export MihomoNormalizeSubscription
func MihomoNormalizeSubscription(input *C.char) *C.char {
	return C.CString(normalizeJSON(C.GoString(input)))
}

// 注：不要定义 func main() —— mihomo 自带的 main.go 已经有 main，会重复声明。
