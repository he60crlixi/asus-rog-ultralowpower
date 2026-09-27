param(
    [string]$Path,      # 目标目录。GUI 传; 省略则用默认目录 (或交互询问)
    [switch]$Silent     # GUI 调用模式: 不提权、不交互、不换行, 输出走 stdout 给界面显示
)
$ErrorActionPreference = 'Stop'

$appName = 'UltraLowPower'
$ver     = '1.0.0'
$unreg   = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$appName"
$here    = Split-Path -Parent $PSCommandPath
$self    = @('install.ps1', 'uninstall.ps1')   # 安装器自己的文件不装进目标目录

# 只有手动在命令行跑的时候才需要自己提权。GUI 已经提过权了, 再提一次会弹第二个 UAC,
# 而且提权后的进程是分离的, stdout 抓不到 -> 界面会一直空着。
if (-not $Silent) {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"') | Out-Null
        exit
    }
}

try {
    Write-Output '正在检查安装包...'

    # ---------- 目标目录 ----------
    if (-not $Path) {
        $prev = $null
        if (Test-Path $unreg) { $prev = (Get-ItemProperty $unreg -ErrorAction SilentlyContinue).InstallLocation }
        $Path = if ($prev -and (Test-Path $prev)) { $prev } else { Join-Path $env:ProgramFiles $appName }
        if (-not $Silent) {
            $ans = Read-Host "默认安装路径: $Path`n直接回车使用该路径, 或输入其它路径"
            if ($ans) { $Path = $ans.Trim().Trim('"') }
        }
    }
    if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    $Path = (Resolve-Path $Path).Path
    $exe  = Join-Path $Path "$appName.exe"

    # 包损坏 / 复制失败都要报出来, 不能静默装一半
    if (-not (Test-Path (Join-Path $here "$appName.exe"))) { throw "安装包不完整: 缺少 $appName.exe" }

    # ---------- 旧版本 ----------
    $prevDir = $null
    if (Test-Path $unreg) { $prevDir = (Get-ItemProperty $unreg -ErrorAction SilentlyContinue).InstallLocation }
    if ($prevDir -and $prevDir -ne $Path) {
        Write-Output "检测到已安装在 $prevDir, 本次装到 $Path。旧目录不会自动删除。"
    }

    # ---------- 复制程序文件 ----------
    Write-Output "正在复制程序文件到 $Path"
    $files = Get-ChildItem $here -File | Where-Object { $self -notcontains $_.Name }
    foreach ($f in $files) { Copy-Item $f.FullName (Join-Path $Path $f.Name) -Force }
    Copy-Item (Join-Path $here 'uninstall.ps1') (Join-Path $Path 'uninstall.ps1') -Force
    if (-not (Test-Path $exe)) { throw "安装失败: 目标目录里没有 $appName.exe" }
    Write-Output ("已安装 {0} 个文件" -f ($files.Count + 1))

    # ---------- 快捷方式 ----------
    Write-Output '正在创建快捷方式...'
    $sh      = New-Object -ComObject WScript.Shell
    $desktop = [Environment]::GetFolderPath('Desktop')
    $start   = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    foreach ($dir in $desktop, $start) {
        $lnk = Join-Path $dir "$appName.lnk"
        $s = $sh.CreateShortcut($lnk)
        $s.TargetPath       = $exe
        $s.WorkingDirectory = $Path
        $s.IconLocation     = "$exe,0"
        $s.Description      = '超低功耗模式控制器'
        $s.Save()
        Write-Output "  $lnk"
    }

    # ---------- 注册"已安装的应用"条目 ----------
    # 这一步是控制面板里"一键卸载"的来源。UninstallString 指向 GUI 版卸载器。
    Write-Output '正在注册卸载项...'
    $uninstaller = Join-Path $Path 'Uninstall.exe'
    $legacy      = Join-Path $Path 'uninstall.ps1'
    $kb = [math]::Round((Get-ChildItem $Path -File | Measure-Object Length -Sum).Sum / 1KB)
    New-Item -Path $unreg -Force | Out-Null
    Set-ItemProperty $unreg 'DisplayName'          'UltraLowPower 超低功耗模式控制器'
    Set-ItemProperty $unreg 'DisplayVersion'       $ver
    Set-ItemProperty $unreg 'Publisher'            'UltraLowPower'
    Set-ItemProperty $unreg 'DisplayIcon'          "$exe,0"
    Set-ItemProperty $unreg 'InstallLocation'      $Path
    if (Test-Path $uninstaller) {
        Set-ItemProperty $unreg 'UninstallString'      ('"' + $uninstaller + '"')
        Set-ItemProperty $unreg 'QuietUninstallString' ('"' + $uninstaller + '" -quiet')
    } else {
        Set-ItemProperty $unreg 'UninstallString'      ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $legacy + '"')
    }
    Set-ItemProperty $unreg 'NoModify'    1 -Type DWord
    Set-ItemProperty $unreg 'NoRepair'    1 -Type DWord
    Set-ItemProperty $unreg 'EstimatedSize' $kb -Type DWord

    Write-Output ''
    Write-Output '安装完成。'
    exit 0
}
catch {
    Write-Output ''
    Write-Output ('安装失败: ' + $_.Exception.Message)
    exit 1
}

# 命令行直接跑(非 -Silent)时给个收尾提示
if (-not $Silent) { Read-Host '按回车关闭此窗口' }
