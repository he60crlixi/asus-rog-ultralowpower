# UltraLowPower 安装包构建脚本 (零外部依赖)
#   powershell -NoProfile -ExecutionPolicy Bypass -File installer\build.ps1
# 产物: dist\UltraLowPower-Setup.exe  单文件安装向导, 双击即装, 约 35 KB
#       dist\Uninstall.exe            同一个源码编出来的卸载向导(打进安装包)
#
# 为什么自己写而不���现成打包器:
#   - IExpress: 这个 Windows 11 build 26100 上缺 wibext.dll(打包引擎), 最小样例都 exit 1
#   - Inno Setup / NSIS: 要另外下载安装, 本机网络拉不到 (GitHub 实测 1.2 KB/s)
#   - .NET 自带 System.IO.Compression + 自带 csc.exe: 都在, 直接用
$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)   # ...\UltraLowPower
$appDir  = Join-Path $root 'app'
$instDir = Join-Path $root 'installer'
$dist    = Join-Path $root 'dist'
$stage   = Join-Path $env:TEMP 'ULPSetupStage'
$zip     = Join-Path $env:TEMP 'ULPSetupPayload.zip'
$setupExe = Join-Path $dist 'UltraLowPower-Setup.exe'
$uninstExe = Join-Path $dist 'Uninstall.exe'
$csc     = "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path $csc)) { throw "找不到 C# 编译器: $csc" }
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# ---------- 编译两个向导 ----------
# /target:winexe  -> PE Subsystem=2, 除了向导窗口和一次 UAC 不会闪黑窗口
# /define:UNINSTALLER -> 同一个 Setup.cs 编出卸载器, 默认就是卸载模式
# 引用列表必须是数组: 写成单个字符串会被 csc 当成一个文件名 (error CS0006)
$refs = @('/r:System.Windows.Forms.dll',
          '/r:System.Drawing.dll',
          '/r:System.IO.Compression.dll',
          '/r:System.IO.Compression.FileSystem.dll')
Write-Host '编译安装向导...'
& $csc /nologo /target:winexe /optimize+ "/out:$setupExe" $refs (Join-Path $instDir 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "安装向导编译失败, exit=$LASTEXITCODE" }

Write-Host '编译卸载向导...'
& $csc /nologo /target:winexe /optimize+ /define:UNINSTALLER "/out:$uninstExe" $refs (Join-Path $instDir 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "卸载向导编译失败, exit=$LASTEXITCODE" }

# ---------- 打包清单 ----------
# 刻意不包含: .verify.ps1(开发自检) / .diag*(已废弃的诊断) / .ref_GPUMode.cs(参考副本)
#             / Silent_PowerScheme_Backup.reg(装机当时的注册表快照, 对别人没有意义)
$files = [ordered]@{
    'UltraLowPower.exe'        = Join-Path $appDir 'UltraLowPower.exe'
    'Uninstall.exe'            = $uninstExe
    'UltraLowPower.ps1'        = Join-Path $appDir 'UltraLowPower.ps1'
    'UltraLowPowerLauncher.cs' = Join-Path $appDir 'UltraLowPowerLauncher.cs'
    'start-ulp.bat'            = Join-Path $appDir 'start-ulp.bat'
    'README.md'                = Join-Path $root   'README.md'
    'install.ps1'              = Join-Path $instDir 'install.ps1'
    'uninstall.ps1'            = Join-Path $instDir 'uninstall.ps1'
}

# 主程序启动器也从源码重编一次: 改了 Launcher.cs 就不用记着单独编
Write-Host '编译主程序启动器...'
& $csc /nologo /target:winexe /optimize+ "/out:$(Join-Path $appDir 'UltraLowPower.exe')" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll (Join-Path $appDir 'UltraLowPowerLauncher.cs')
if ($LASTEXITCODE -ne 0) { throw "启动器编译失败, exit=$LASTEXITCODE" }

# ---------- 1. 暂存 ----------
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($k in $files.Keys) {
    if (-not (Test-Path $files[$k])) { throw "缺少文件: $($files[$k])" }
    Copy-Item $files[$k] (Join-Path $stage $k) -Force
}
# install/uninstall.ps1 含中文, 必须是 UTF-8 with BOM —— PowerShell 5.1 读无 BOM 会按 GBK 解,
# 结果是 ParserError 且没有任何输出(这个坑本项目已经踩过两次)。
foreach ($k in 'install.ps1', 'uninstall.ps1') {
    $p = Join-Path $stage $k
    $t = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
    [IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------- 2. 打 zip ----------
Remove-Item $zip, $setupExe -Force -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)

# ---------- 3. payload 以资源形式嵌进安装向导 ----------
Write-Host '嵌入 payload...'
& $csc /nologo /target:winexe /optimize+ "/out:$setupExe" "/resource:$zip,SfxPayload.zip" $refs (Join-Path $instDir 'Setup.cs')
if ($LASTEXITCODE -ne 0) { throw "嵌入 payload 后重编失败, exit=$LASTEXITCODE" }

Remove-Item $zip, $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
foreach ($f in @($setupExe, $uninstExe)) {
    $o = Get-Item $f
    Write-Host ("  {0,-52} {1,8:N0} 字节" -f $o.Name, $o.Length) -ForegroundColor Green
}
Write-Host "  内含 $($files.Count) 个文件; 不含 .verify / .diag / .ref / .reg"
