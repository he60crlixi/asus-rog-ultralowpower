param(
    [switch]$Quiet    # 控制面板/任务栏静默卸载: 不显示完成页(仍然弹 UAC)
)
$ErrorActionPreference = 'Continue'

$appName = 'UltraLowPower'
$unreg   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$appName"
$dir     = Split-Path -Parent $PSCommandPath
$ps1     = Join-Path $dir 'UltraLowPower.ps1'

# ---------- 最要紧的一步: 先把电源设置恢复, 再删任何东西 ----------
# state.json / backup.csv 存在 = 程序开过超低功耗模式 = CPU 上限 25% / 频率 1GHz 还锁着。
# 真正救命的是 backup.csv(15 项设置 x 6 电源方案的原值都在里面), state.json 是"当前还开着"的标志。
# 两个都认: 开启过程崩在写 state.json 之前就只剩 backup.csv, 那恰恰最需要恢复。
# 先删文件的话这些设置会永久留在注册表里, 而且没有任何界面能改回来(全被锁在 25%)。
$state = Join-Path $dir 'state.json'
$csv   = Join-Path $dir 'backup.csv'
if ((Test-Path $state) -or (Test-Path $csv)) {
    Write-Output '检测到超低功耗模式开过, 正在先恢复电源设置...'
    if (Test-Path $ps1) {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $ps1 -Action disable 2>&1 | ForEach-Object { Write-Output "  $_" }
        if ((Test-Path $state) -or (Test-Path $csv)) {
            Write-Output '  [!] 标记文件仍在, 电源设置可能没恢复干净。请重新安装后再卸载一次。'
            exit 2
        }
        Write-Output '  电源设置已恢复。'
    } else {
        Write-Output '  [!] 找不到 UltraLowPower.ps1, 无法自动恢复。'
        Write-Output '      请手动把电源方案里的最大处理器状态改回 100%。'
        exit 2
    }
} else {
    Write-Output '超低功耗模式未开启, 无需恢复电源设置。'
}

# ---------- 快捷方式 ----------
Write-Output '正在删除快捷方式...'
$sh      = New-Object -ComObject WScript.Shell
$desktop = [Environment]::GetFolderPath('Desktop')
$start   = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
foreach ($lnk in @((Join-Path $desktop "$appName.lnk"), (Join-Path $start "$appName.lnk"))) {
    if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue; Write-Output "  $lnk" }
}

# ---------- 注册条目 ----------
if (Test-Path $unreg) { Remove-Item $unreg -Recurse -Force -ErrorAction SilentlyContinue }

# ---------- 目录 ----------
# 脚本自己还在这个目录里跑, 删不掉自己。丢一个延时进程, 等调用方(卸载器 exe)退出后再删。
# 删两次: 第一次等卸载器 exe 退出(它会连带锁住 Uninstall.exe), 第二次再补一刀把空目录收掉。
Write-Output '正在删除安装目录...'
Start-Process cmd.exe -ArgumentList '/c', "ping -n 4 127.0.0.1 >nul & rmdir /s /q `"$dir`" & ping -n 2 127.0.0.1 >nul & rmdir /s /q `"$dir`"" -WindowStyle Hidden | Out-Null
Write-Output ''
Write-Output '卸载完成。'
exit 0
