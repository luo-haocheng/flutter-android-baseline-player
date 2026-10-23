# 在模拟器上运行本项目（开发调试，支持热重载）
#
# 用法：
#   .\scripts\run-emulator.ps1            # 默认 emulator-5554
#   .\scripts\run-emulator.ps1 -Device emulator-5556
#
# 说明：脚本会先把国内镜像等环境变量设好，再调用 `flutter run`。
# 这样就不会出现"卡在下载 Flutter 引擎产物"的问题。

param(
    [string]$Device = 'emulator-5554',
    [string]$Avd = 'Medium_Phone'
)

$ErrorActionPreference = 'Stop'

# --- 环境变量（只影响当前这个终端窗口）---
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL           = 'https://pub.flutter-io.cn'
$env:ANDROID_HOME             = 'D:\Android\SDK'
$env:ANDROID_SDK_ROOT         = 'D:\Android\SDK'
$env:JAVA_HOME                = 'D:\Android\Android_Studio\jbr'
$env:Path                     = 'D:\flutter\bin;D:\Android\SDK\platform-tools;' + $env:Path

$adb      = 'D:\Android\SDK\platform-tools\adb.exe'
$emulator = 'D:\Android\SDK\emulator\emulator.exe'

# --- 模拟器没启动就帮你启动 ---
$connected = (& $adb devices) -join "`n"
if ($connected -notmatch [regex]::Escape($Device)) {
    Write-Host "模拟器 $Device 未运行，正在启动 AVD: $Avd ..." -ForegroundColor Yellow
    Start-Process -FilePath $emulator -ArgumentList '-avd', $Avd, '-no-audio', '-no-boot-anim'
    & $adb wait-for-device
    do {
        Start-Sleep -Seconds 2
        $booted = (& $adb -s $Device shell getprop sys.boot_completed 2>$null) -join ''
    } until ($booted -match '1')
    Write-Host '模拟器已启动完成。' -ForegroundColor Green
}

Write-Host "在 $Device 上运行 Flutter 应用（改完代码按 r 热重载，按 q 退出）" -ForegroundColor Green
flutter run -d $Device
