# Windows 侧编译 mihomo 为 OHOS musl 目标
#
# 本脚本解决的核心问题：
#   Go 的外部链接器调用（clang.exe）需要正确的 --target/--sysroot，
#   但 Go 对 CGO_LDFLAGS 有白名单校验，不允许随意传参。
#   官方通道是 -ldflags "-extldflags '...'"。
#
#   同时 NDK 路径含空格（DevEco Studio），Go 会按空格切分 CC，
#   所以所有路径都用 8.3 短路径。

$ErrorActionPreference = 'Stop'

$PROJECT = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if ([string]::IsNullOrWhiteSpace($env:OHOS_GO_HOME) -or
    [string]::IsNullOrWhiteSpace($env:MIHOMO_SOURCE_DIR)) {
  throw '请设置 OHOS_GO_HOME（OHOS Go 工具链目录）和 MIHOMO_SOURCE_DIR（Mihomo 源码目录）。'
}
$GO = Join-Path $env:OHOS_GO_HOME 'bin/go.exe'
$BUILD = Join-Path $PROJECT '.local-build/mihomo'
if (!(Test-Path -LiteralPath (Join-Path $env:MIHOMO_SOURCE_DIR 'go.mod'))) {
  throw 'MIHOMO_SOURCE_DIR 必须指向含 go.mod 的 Mihomo 源码目录。'
}
New-Item -ItemType Directory -Force -Path $BUILD | Out-Null
Get-ChildItem -LiteralPath $env:MIHOMO_SOURCE_DIR -Force |
  Where-Object { $_.Name -ne '.git' } |
  Copy-Item -Destination $BUILD -Recurse -Force
Copy-Item (Join-Path $PSScriptRoot 'cshared_main.go') $BUILD
Copy-Item (Join-Path $PSScriptRoot 'subscription.go') $BUILD

$sdkRoot = $env:DEVECO_SDK_HOME
if ([string]::IsNullOrWhiteSpace($sdkRoot)) {
  throw '请先设置 DEVECO_SDK_HOME，指向 DevEco Studio 的 sdk 目录。'
}
$nativeRoot = Join-Path $sdkRoot 'default/openharmony/native'
$fso = New-Object -ComObject Scripting.FileSystemObject
$CC      = $fso.GetFile((Join-Path $nativeRoot 'llvm/bin/clang.exe')).ShortPath
$CXX     = $fso.GetFile((Join-Path $nativeRoot 'llvm/bin/clang++.exe')).ShortPath
$LDLLD   = $fso.GetFile((Join-Path $nativeRoot 'llvm/bin/ld.lld.exe')).ShortPath
$SYSROOT = $fso.GetFolder((Join-Path $nativeRoot 'sysroot')).ShortPath

Write-Output "CC: $CC"
Write-Output "SYSROOT: $SYSROOT"

$env:GOOS = 'openharmony'
$env:GOARCH = 'arm64'
$env:CGO_ENABLED = '1'
$env:GOTOOLCHAIN = 'local'
$env:GOFLAGS = '-trimpath'
$env:CC = $CC
$env:CXX = $CXX
$base = "--target=aarch64-linux-ohos --sysroot=$SYSROOT"
$env:CGO_CFLAGS = "$base -ftls-model=global-dynamic"
$env:CGO_CPPFLAGS = $env:CGO_CFLAGS
$env:CGO_CXXFLAGS = $env:CGO_CFLAGS
$env:CGO_LDFLAGS = ""
$env:TMP = Join-Path $PROJECT '.local-build/gotmp'
$env:TEMP = $env:TMP
$env:GOTMPDIR = $env:TMP
New-Item -ItemType Directory -Force -Path $env:TMP | Out-Null

Set-Location $BUILD
Remove-Item 'libmihomo_core.so','libmihomo_core.h' -ErrorAction SilentlyContinue

# 构造 -extldflags
$extld = "-fuse-ld=$LDLLD $base"
Write-Output "extldflags: $extld"

# Go 的 -ldflags 参数在 PowerShell 里容易因引号嵌套出错，
# 这里用数组形式逐个参数传递，避免 shell 解析问题。
$ldflagsValue = "-s -w -buildid= -X github.com/metacubex/mihomo/constant.Version=1.10.0-ohos-musl -extldflags `"$extld`""

Write-Output ""
Write-Output "=== 编译 ==="
$args1 = @('build', '-p', '4', '-buildmode=c-shared', '-ldflags', $ldflagsValue, '-o', 'libmihomo_core.so', '.')
$out = & $GO @args1 2>&1
$out | Select-Object -Last 25

Write-Output ""
if (Test-Path 'libmihomo_core.so') {
  $f = Get-Item 'libmihomo_core.so'
  Copy-Item (Join-Path $BUILD 'libmihomo_core.so') (Join-Path $PROJECT 'entry/libs/arm64-v8a/libmihomo_core.so')
  Write-Output ("✅ 编译成功: " + [math]::Round($f.Length/1MB,2) + " MB")
} else {
  throw "内核编译失败"
}
