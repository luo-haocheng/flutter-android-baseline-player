# 修复 Android Studio Flutter 插件 "Timeout when calling flutter config --machine"
#
# 背景：flutter-intellij 97.x 里把 `flutter config --machine` 的等待时间写死成 5 秒。
# 本机在 IDE 里同时发起两次调用时会排队（flutter 有启动锁），总耗时偶尔超过 5 秒，
# 于是插件报 Timeout → Dart 分析不启动、Gradle 不导入、Logcat 报
# "Could not detect project package names. Is the project synced?"、代码全是红波浪线。
#
# 这个脚本把该常量从 5000 毫秒改成 30000 毫秒（30 秒），其余字节不动。
# 会自动备份原 jar 为 *.jar.bak；升级插件后可能需要重新执行。
#
# 用法：
#   1) 完全退出 Android Studio（File → Exit）
#   2) 在 PowerShell 里执行： .\scripts\patch-flutter-plugin-timeout.ps1
#   3) 重新打开 Android Studio

$ErrorActionPreference = 'Stop'

$newTimeoutMs = 30000
$oldBytes = [byte[]](0,0,0,0,0,0,0x13,0x88)         # long 5000
$newBytes = [bitconverter]::GetBytes([long]$newTimeoutMs)
[array]::Reverse($newBytes)                          # 大端

$roots = Get-ChildItem "$env:APPDATA\Google" -Directory -Filter 'AndroidStudio*' -ErrorAction SilentlyContinue
$patched = 0

foreach ($root in $roots) {
    $lib = Join-Path $root.FullName 'plugins\flutter-intellij\lib'
    if (-not (Test-Path $lib)) { continue }

    $jar = Get-ChildItem $lib -Filter 'flutter-intellij-*.jar' |
           Where-Object { $_.Name -notlike '*.bak' -and $_.Name -notlike '*searchableOptions*' } |
           Sort-Object Length -Descending | Select-Object -First 1
    if (-not $jar) { continue }

    Write-Host "找到插件: $($jar.FullName)"

    try {
        $fs = [System.IO.File]::Open($jar.FullName, 'Open', 'ReadWrite', 'None')
        $fs.Close()
    } catch {
        Write-Warning "  -> 文件被占用，请先完全退出 Android Studio 再运行本脚本。"
        continue
    }

    $backup = "$($jar.FullName).bak"
    if (-not (Test-Path $backup)) { Copy-Item $jar.FullName $backup; Write-Host "  已备份: $backup" }

    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($jar.FullName, 'Update')
    try {
        $entry = $zip.GetEntry('io/flutter/sdk/FlutterSdk.class')
        if (-not $entry) { Write-Warning "  -> 没找到 FlutterSdk.class，跳过"; continue }

        $ms = New-Object System.IO.MemoryStream
        $s = $entry.Open(); $s.CopyTo($ms); $s.Dispose()
        $bytes = $ms.ToArray(); $ms.Dispose()

        $index = -1
        for ($i = 0; $i -le $bytes.Length - 8; $i++) {
            $hit = $true
            for ($j = 0; $j -lt 8; $j++) { if ($bytes[$i + $j] -ne $oldBytes[$j]) { $hit = $false; break } }
            if ($hit) { $index = $i; break }
        }

        if ($index -lt 0) {
            Write-Warning "  -> 没找到 5000ms 常量（插件版本可能已变），未修改。"
            continue
        }

        [array]::Copy($newBytes, 0, $bytes, $index, 8)
        $entry.Delete()
        $newEntry = $zip.CreateEntry('io/flutter/sdk/FlutterSdk.class', [System.IO.Compression.CompressionLevel]::Optimal)
        $out = $newEntry.Open(); $out.Write($bytes, 0, $bytes.Length); $out.Dispose()
        $patched++
        Write-Host "  -> 已把超时从 5000ms 改为 $($newTimeoutMs)ms" -ForegroundColor Green
    }
    finally {
        $zip.Dispose()
    }
}

if ($patched -eq 0) {
    Write-Host "没有修改任何文件。" -ForegroundColor Yellow
} else {
    Write-Host "完成。请重新打开 Android Studio，等它重新索引（Indexing / Sync）。" -ForegroundColor Green
}
