# ============================================================
#  超低功耗模式控制器  (Ultra Low Power Mode; 参考机型实测 13.7W)
#  适用: ASUS ROG G615LR = 枪神9 / 魔霸新锐 2025 (官网产品线 G615 全系同板同 ATK 接口)
#  参考实测功耗 13.7W 只对应本机配置(275HX + RTX 5070 Ti + 72.8Wh), 不是产品标称,
#  换配置请以 GUI 里的实时放电读数为准。
#        Windows 11 (2026-09-27 按实机诊断重写)
#  开启: 锁定全部电源方案 CPU ~1.2GHz / 2核 / 禁睿频 / 屏幕20%
#        刷新率 -> 60Hz(最低常规档, CDS_TEST 验证后应用)
#        独显直连 -> 混合+核显Eco(MUX 硬开关需重启生效)
#  退出: 电源方案/刷新率/独显模式 逐项恢复
# ============================================================

param(
    [ValidateSet('gui','enable','disable')]
    [string]$Action = 'gui'
)

$ErrorActionPreference = 'Stop'

# ---------- 自动提权 ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',("`"" + $PSCommandPath + "`""),('-Action ' + $Action)
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---------- 显示/刷新率 (EnumDisplayDevices + ChangeDisplaySettingsEx, CDS_TEST 预检) ----------
$DisplayCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace ULPNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion;
        public ushort dmDriverVersion;
        public ushort dmSize;
        public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX;
        public int dmPositionY;
        public uint dmDisplayOrientation;
        public uint dmDisplayFixedOutput;
        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels;
        public uint dmBitsPerPel;
        public uint dmPelsWidth;
        public uint dmPelsHeight;
        public uint dmDisplayFlags;
        public uint dmDisplayFrequency;
        public uint dmICMMethod;
        public uint dmICMIntent;
        public uint dmMediaType;
        public uint dmDitherType;
        public uint dmReserved1;
        public uint dmReserved2;
        public uint dmPanningWidth;
        public uint dmPanningHeight;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public uint StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    public class Display
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDeviceOut, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE dm);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern int ChangeDisplaySettingsEx(string deviceName, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr lParam);

        static ushort SZ() { return (ushort)Marshal.SizeOf(typeof(DEVMODE)); }

        public static string[] ListDisplays()
        {
            List<string> names = new List<string>();
            for (uint d = 0; d < 8; d++)
            {
                DISPLAY_DEVICE dd = new DISPLAY_DEVICE();
                dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
                if (!EnumDisplayDevices(null, d, ref dd, 0)) break;
                if ((dd.StateFlags & 1) == 0) continue; // 没有桌面的跳过
                names.Add(dd.DeviceName);
            }
            return names.ToArray();
        }

        public static int CurrentFreq(string dev)
        {
            DEVMODE dm = new DEVMODE(); dm.dmSize = SZ();
            if (!EnumDisplaySettings(dev, -1, ref dm)) return 0;
            return (int)dm.dmDisplayFrequency;
        }

        public static int[] AvailableFreqs(string dev)
        {
            DEVMODE cur = new DEVMODE(); cur.dmSize = SZ();
            if (!EnumDisplaySettings(dev, -1, ref cur)) return new int[0];
            List<int> freqs = new List<int>();
            for (int i = 0; i < 512; i++)
            {
                DEVMODE dm = new DEVMODE(); dm.dmSize = SZ();
                if (!EnumDisplaySettings(dev, i, ref dm)) break;
                if (dm.dmPelsWidth == cur.dmPelsWidth && dm.dmPelsHeight == cur.dmPelsHeight && dm.dmBitsPerPel == cur.dmBitsPerPel)
                {
                    int f = (int)dm.dmDisplayFrequency;
                    if (f >= 20 && f <= 500 && !freqs.Contains(f)) freqs.Add(f);
                }
            }
            freqs.Sort();
            return freqs.ToArray();
        }

        // 返回 0=成功, 1=构造模式失败, 2=系统拒绝该模式(CDS_TEST), 3=应用失败
        public static int SetFrequency(string dev, int hz)
        {
            DEVMODE dm = new DEVMODE(); dm.dmSize = SZ();
            if (!EnumDisplaySettings(dev, -1, ref dm)) return 1;
            dm.dmDisplayFrequency = (uint)hz;
            dm.dmFields = 0x00040000 | 0x00080000 | 0x00100000 | 0x00400000; // BITSPERPEL|PELSWIDTH|PELSHEIGHT|FREQUENCY
            int test = ChangeDisplaySettingsEx(dev, ref dm, IntPtr.Zero, 0x00000002, IntPtr.Zero); // CDS_TEST
            if (test != 0) return 2;
            int apply = ChangeDisplaySettingsEx(dev, ref dm, IntPtr.Zero, 0x00000001, IntPtr.Zero); // CDS_UPDATEREGISTRY
            return apply == 0 ? 0 : 3;
        }
    }
}
'@
Add-Type -TypeDefinition $DisplayCs

# ---------- 华硕 ATK 接口 (\\.\ATKACPI + 0x22240C, 参考 G-Helper; DSTS 参数固定 8 字节) ----------
$AtkCs = @'
using System;
using System.Runtime.InteropServices;

namespace ULPNative
{
    public class Atk
    {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(IntPtr h, uint code, byte[] inBuf, uint inSize, byte[] outBuf, uint outSize, out uint returned, IntPtr overlapped);

        static IntPtr handle = IntPtr.Zero;
        static bool initTried = false;

        // DEVS=0x53564544  DSTS=0x53545344  INIT=0x54494E49 (与 G-Helper 一致)
        const uint METHOD_DEVS = 0x53564544u;
        const uint METHOD_DSTS = 0x53545344u;
        const uint METHOD_INIT = 0x54494E49u;
        const uint ATK_CONTROL_CODE = 0x0022240Cu;

        public static bool Open()
        {
            if (handle != IntPtr.Zero) return true;
            handle = CreateFileW("\\\\.\\ATKACPI", 0xC0000000u, 3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero);
            if (handle == new IntPtr(-1) || handle == IntPtr.Zero) { handle = IntPtr.Zero; return false; }
            if (!initTried)
            {
                initTried = true;
                byte[] buf = new byte[16];
                BitConverter.GetBytes(METHOD_INIT).CopyTo(buf, 0);
                BitConverter.GetBytes(8u).CopyTo(buf, 4);
                uint ret;
                byte[] outB = new byte[16];
                DeviceIoControl(handle, ATK_CONTROL_CODE, buf, 16, outB, 16, out ret, IntPtr.Zero);
            }
            return true;
        }

        static byte[] Call(uint method, byte[] args)
        {
            byte[] buf = new byte[8 + args.Length];
            byte[] outBuf = new byte[16];
            BitConverter.GetBytes(method).CopyTo(buf, 0);
            BitConverter.GetBytes((uint)args.Length).CopyTo(buf, 4);
            args.CopyTo(buf, 8);
            uint returned;
            DeviceIoControl(handle, ATK_CONTROL_CODE, buf, (uint)buf.Length, outBuf, (uint)outBuf.Length, out returned, IntPtr.Zero);
            return outBuf;
        }

        // DEVS 写入, 返回 1 = 成功
        public static int Devs(uint deviceId, uint status)
        {
            if (!Open()) return -999;
            byte[] args = new byte[8];
            BitConverter.GetBytes(deviceId).CopyTo(args, 0);
            BitConverter.GetBytes(status).CopyTo(args, 4);
            return BitConverter.ToInt32(Call(METHOD_DEVS, args), 0);
        }

        // DSTS 读取, 返回原始值(含 0x10000 presence 位), 0/负 = 不支持
        public static int Dsts(uint deviceId)
        {
            if (!Open()) return -999;
            byte[] args = new byte[8];
            BitConverter.GetBytes(deviceId).CopyTo(args, 0);
            return BitConverter.ToInt32(Call(METHOD_DSTS, args), 0);
        }
    }
}
'@
Add-Type -TypeDefinition $AtkCs

$AppDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$StateFile = Join-Path $AppDir 'state.json'

# ---------- 电源设置 GUID ----------
$SUB_CPU   = '54533251-82be-4824-96c1-47b60b740d00'
$CPU_MIN   = '893dee8e-2bef-41e0-89c6-b55d0929964c'  # 最小处理器状态 %
$CPU_MAX   = 'bc5038f7-23e0-4960-96da-33abaf5935ec'  # 最大处理器状态 %
$CPU_FREQ  = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'  # 最大处理器频率 MHz
$CPU_CORES = 'ea062031-0e34-4ff1-9b6d-eb1059334028'  # 最大处理器核心数 %
$CPU_BOOST = 'be337238-0d82-4146-a960-4f3749d470c7'  # 处理器性能提升模式
$SUB_DISK  = '0012ee47-9041-4b5d-9b77-535fba8b1442'
$DISK_OFF  = '6738e2c4-e8a5-4a42-b16a-e040e769756e'  # 关闭硬盘(秒)
$SUB_VIDEO = '7516b95f-f776-4464-8c53-06167f40cc99'
$VID_OFF   = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'  # 关闭显示(秒)
$VID_BRI   = 'aded5e82-b909-4619-9949-f5d71dac0bcb'  # 显示器亮度 %
$SUB_IGP   = '44f3beca-a7c0-460e-9df2-bb8b99e0cba6'
$IGP_PLAN  = '3619c3f2-afb2-4afc-b0e9-e7fef372de36'  # Intel核显电源计划 0=最大续航
$SUB_PCIE  = '501a4d13-42af-4429-9fd1-a8218c268e20'
$ASPM      = 'ee12f906-d277-404b-b6da-e5fa1a576df5'  # ASPM 2=最大省电
$SUB_USB   = '2a737441-1930-4402-8d77-b2bebba308a3'
$USB_SUSP  = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'  # USB选择性暂停 1=启用
$SUB_WIFI  = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'
$WIFI_SAVE = '12bbebe6-58d6-4636-95bb-3217ef867c1a'  # 无线节能 3=最高
$SUB_MEDIA = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'
$MED_COMP  = '10778347-1370-4ee0-8bbd-33bdacaade49'  # 视频质量补偿 0=节能
$MED_PLAY  = '34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4'  # 播放视频 2=优化节能
$SUB_IE    = '02f815b5-a5cf-4c84-bf20-649d1f75d3d8'
$JS_TIMER  = '4c793e7d-a264-42e1-87d3-7a0d2f523ccd'  # JS计时器 0=最大省电

# 超低功耗设置表 (子组, 设置, 值)
$LowSets = @(
    ,@($SUB_CPU,  $CPU_MIN,   1)
    ,@($SUB_CPU,  $CPU_MAX,   25)
    ,@($SUB_CPU,  $CPU_FREQ,  1000)
    ,@($SUB_CPU,  $CPU_CORES, 8)
    ,@($SUB_CPU,  $CPU_BOOST, 0)
    ,@($SUB_DISK, $DISK_OFF,  300)
    ,@($SUB_VIDEO,$VID_OFF,   120)
    ,@($SUB_VIDEO,$VID_BRI,   20)
    ,@($SUB_IGP,  $IGP_PLAN,  0)
    ,@($SUB_PCIE, $ASPM,      2)
    ,@($SUB_USB,  $USB_SUSP,  1)
    ,@($SUB_WIFI, $WIFI_SAVE, 3)
    ,@($SUB_MEDIA,$MED_COMP,  0)
    ,@($SUB_MEDIA,$MED_PLAY,  2)
    ,@($SUB_IE,   $JS_TIMER,  0)
)

# ---------- 华硕设备常量 (语义按 G-Helper 源码核实: mux 0=独显直连 1=混合; eco 1=独显断电) ----------
$GPU_MUX   = 0x00090016   # MUX 硬件开关, 切换需重启
$GPU_ECO   = 0x00090020   # Eco 混合模式下实时生效

function Get-AllSchemes {
    $list = powercfg /list
    $list | Select-String -Pattern '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})' |
        ForEach-Object { $_.Matches[0].Value } | Sort-Object -Unique
}

function Get-ActiveScheme {
    $out = (powercfg /getactivescheme) -join ' '
    $m = [regex]::Match($out, '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})')
    return $m.Groups[1].Value
}

# 读取电源设置原值。刻意走注册表而不是 powercfg /q: /q 的字段名是本地化的
# (中文"当前交流电源设置索引:"), 跟着系统语言变就会解析失败 -> 设置改了却没进 backup.csv
# -> 点退出恢复不回去, CPU 永久锁 1GHz。注册表布局与语言无关, 实测 6 方案 x 15 设置全都有键。
function Get-SettingIndex($scheme, $sub, $set) {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
        "SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes\$scheme\$sub\$set")
    if (-not $k) { return $null }
    try {
        $ac = $k.GetValue('ACSettingIndex')
        $dc = $k.GetValue('DCSettingIndex')
        if ($null -eq $ac -or $null -eq $dc) { return $null }
        return @{ ac = [int]$ac; dc = [int]$dc }
    } finally { $k.Close() }
}

# 独显实测功耗(W)。nvidia-smi 读不到 = $null = 独显已断电或驱动未加载。
# 只在 dGPU 本来就上电的状态下调用(MUX/Eco 切换时), 查询本身不额外费电。
function Get-DgpuWatts {
    $exe = (Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue).Source
    if (-not $exe) {
        $exe = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        if (-not (Test-Path $exe)) { return $null }
    }
    try {
        $o = & $exe --query-gpu=power.draw --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $o) { return $null }
        return [math]::Round([double](($o | Select-Object -First 1).Trim()), 1)
    } catch { return $null }
}

# Eco=1 之后别只信 ATK 说"写成功": 有程序占着独显时指令会落地但 dGPU 照样耗电
function Get-EcoNote {
    $w = Get-DgpuWatts
    if ($null -eq $w) { return '独显已断电(Eco; nvidia-smi 无响应)' }
    if ($w -gt 1) { return ('Eco 已写入, 但独显仍在耗电 {0}W —— 有程序在用独显, 关掉再开一次' -f $w) }
    return ('独显已断电(Eco, 实测 {0}W)' -f $w)
}

# "满血性能有没有真的回来"。光看 MUX 寄存器不够: 写进去 0 之后, 硬件要等重启才切,
# 这期间寄存器已经报 0 但独显还是关的 —— 只看寄存器会误判成"已恢复, 不用重启"。
# 独显有没有上电用 nvidia-smi 读, 读不到就是没上电。
function Need-GpuReboot {
    $mux = Get-AsusDevValue -DevId $GPU_MUX
    if ($mux -ne $null -and $mux -ne 0) { return $true }   # 待生效值还是混合
    if ($null -eq (Get-DgpuWatts)) { return $true }         # 寄存器说直连, 但独显还没上电
    return $false
}

# ---------- 华硕 ATK 读/写 (ATKACPI 主通道, 本机无 WMI Asus 类) ----------
function Get-AsusDevValue {
    param([uint32]$DevId)
    $raw = [ULPNative.Atk]::Dsts($DevId)
    if ($raw -gt 0) {
        $v = $raw - 0x10000
        if ($v -ge 0) { return $v }
    }
    return $null
}

function Set-AsusDevValue {
    param([uint32]$DevId, [uint32]$Value)
    return ([ULPNative.Atk]::Devs($DevId, $Value) -eq 1)
}

# 重启会作废两件事, 这次一并补上:
#   1. MUX 是硬件开关, 切混合要重启才生效 -> 补写 Eco
#   2. CPU 最大频率 / 最大核心数 enable 时写入成功, 但重启后被 ASUS 性能配置写回 0/0 和 100/100 -> 补写
function Sync-AfterReboot {
    $parts = @()
    try {
        $st = Get-Content $StateFile -Raw | ConvertFrom-Json
        if (-not $st.Enabled) { return '' }
        if ($st.GpuMuxChanged -and (Get-AsusDevValue -DevId $GPU_MUX) -eq 1) {
            if ((Get-AsusDevValue -DevId $GPU_ECO) -eq 1) { $parts += '重启完成, ' + (Get-EcoNote) }
            elseif (Set-AsusDevValue -DevId $GPU_ECO -Value 1) { $parts += '重启完成, ' + (Get-EcoNote) }
        }
        # 补写要覆盖所有方案, 不只是当前生效的: Armoury Crate 拔电会自动切到 Silent,
        # 只补当前方案的话, 切过去的那个方案 CPU 频率/核心数是放开的
        foreach ($s in (Get-AllSchemes)) {
            foreach ($pair in @(@($CPU_FREQ, 1000), @($CPU_CORES, 8))) {
                powercfg /setacvalueindex $s $SUB_CPU $pair[0] $pair[1] | Out-Null
                powercfg /setdcvalueindex $s $SUB_CPU $pair[0] $pair[1] | Out-Null
            }
        }
    } catch { }
    return ($parts -join '; ')
}

# ---------- 刷新率: 每台活动显示器降档 (60 优先, 其次 >=60 最低, 最后才更低档) ----------
function Set-DisplayLow {
    $info = @{ Items = @(); Note = '' }
    foreach ($dev in [ULPNative.Display]::ListDisplays()) {
        try {
            $cur = [ULPNative.Display]::CurrentFreq($dev)
            $all = [ULPNative.Display]::AvailableFreqs($dev)
            $cands = @($all | Where-Object { $_ -lt $cur })
            if ($cands.Count -eq 0) { continue }
            $target = $null
            if ($cands -contains 60) { $target = 60 }
            else {
                $hi = @($cands | Where-Object { $_ -ge 60 })
                if ($hi.Count -gt 0) { $target = ($hi | Measure-Object -Minimum).Minimum }
                else { $target = ($cands | Measure-Object -Minimum).Minimum }
            }
            $rc = [ULPNative.Display]::SetFrequency($dev, $target)
            if ($rc -eq 0) {
                $info.Items += ('{0}|{1}' -f $dev, $cur)
                $info.Note += ('{0}: {1}Hz->{2}Hz  ' -f $dev, $cur, $target)
            } else {
                $info.Note += ('{0}: 降到{1}Hz失败(code {2})  ' -f $dev, $target, $rc)
            }
        } catch { }
    }
    return $info
}

function Restore-Display {
    param([string[]]$Pairs)
    $restored = 0
    foreach ($p in @($Pairs)) {
        if (-not $p) { continue }
        $dev, $hz = $p -split '\|'
        try {
            if ([ULPNative.Display]::SetFrequency($dev, [int]$hz) -eq 0) { $restored++ }
        } catch { }
    }
    return $restored
}

function Enable-ULP {
    # 已开启: 不重复备份, 但补办重启后未完成的事(MUX 重启完成后再落 Eco)
    if (Test-Path $StateFile) {
        $note = Sync-AfterReboot
        return @{ Already = $true; ReconcileNote = $note; RefreshSet = $false; RefreshFrom = $null; RefreshTo = $null;
                  GpuDone = $false; GpuReboot = $false; GpuNote = ''; Warn = '' }
    }

    # ---- 1. 电源方案 ----
    $schemes = Get-AllSchemes
    $rows = @()
    $unbacked = 0
    foreach ($s in $schemes) {
        foreach ($set in $LowSets) {
            $v = Get-SettingIndex $s $set[0] $set[1]
            if ($v) {
                $rows += [pscustomobject]@{ scheme = $s; sub = $set[0]; set = $set[1]; ac = $v.ac; dc = $v.dc }
            } else { $unbacked++ }
            powercfg /setacvalueindex $s $set[0] $set[1] $set[2] | Out-Null
            powercfg /setdcvalueindex $s $set[0] $set[1] $set[2] | Out-Null
        }
    }
    $rows | Export-Csv (Join-Path $AppDir 'backup.csv') -Encoding UTF8 -NoTypeInformation
    powercfg /setactive (Get-ActiveScheme) | Out-Null

    $info = @{ Already = $false; ReconcileNote = ''; RefreshSet = $false; RefreshFrom = $null; RefreshTo = $null;
               GpuDone = $false; GpuReboot = $false; GpuNote = ''; Warn = '' }
    if ($unbacked) { $info.Warn = "$unbacked 项设置读不到原值, 退出时无法恢复" }
    # 写完把生效方案的 15 项读回来核对: powercfg 对某些项(隐藏项)会 exit 0 却什么都不写,
    # 不核对就只能等下次重启才发现没生效。只核对生效方案, 15 次注册表读, 毫秒级。
    $act = Get-ActiveScheme
    $bad = @()
    foreach ($set in $LowSets) {
        $v = Get-SettingIndex $act $set[0] $set[1]
        if (-not $v -or $v.ac -ne $set[2] -or $v.dc -ne $set[2]) { $bad += $set[0].Substring(0, 4) + '/' + $set[1].Substring(0, 4) }
    }
    if ($bad.Count) { $info.Warn = (($info.Warn + '; ').Trim('; ')) + "$($bad.Count) 项未生效: $($bad -join ' ')" }
    $state = @{ Enabled = $true; Time = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }

    # ---- 2. 刷新率 -> 60Hz (或最低常规档) ----
    $rf = Set-DisplayLow
    if ($rf.Items.Count -gt 0) {
        $info.RefreshSet = $true
        $state.RefreshOrig = $rf.Items
        $first = $rf.Items[0] -split '\|'
        $info.RefreshFrom = $first[1]
        $info.RefreshTo = [ULPNative.Display]::CurrentFreq($first[0])
    }

    # ---- 3. 独显 -> 核显模式 ----
    $muxCur = Get-AsusDevValue -DevId $GPU_MUX
    $ecoCur = Get-AsusDevValue -DevId $GPU_ECO
    if ($muxCur -ne $null -or $ecoCur -ne $null) {
        if ($muxCur -eq 0) {
            # 独显直连中: 切回混合(MUX=1)+独显断电(Eco=1), MUX 重启生效
            $muxWrote = Set-AsusDevValue -DevId $GPU_MUX -Value 1
            $ecoWrote = Set-AsusDevValue -DevId $GPU_ECO -Value 1
            if ($muxWrote) {
                $info.GpuDone = $true
                $info.GpuReboot = $true
                $info.GpuNote = '已请求退出独显直连, 重启电脑生效; 重启后独显自动断电'
                $state.GpuMuxOrig = 0
                $state.GpuMuxChanged = $true
            } else {
                $info.GpuNote = 'MUX 切换指令被拒绝'
            }
            if ($ecoWrote -or $ecoCur -eq 1) {
                $state.GpuEcoSet = $true
                $state.GpuEcoOrig = $(if ($ecoCur -ne $null) { $ecoCur } else { 0 })
            }
        } else {
            # 已是混合模式: 直接断独显
            if ($ecoCur -eq 1) {
                $info.GpuDone = $true
                $info.GpuNote = Get-EcoNote
            } elseif (Set-AsusDevValue -DevId $GPU_ECO -Value 1) {
                $info.GpuDone = $true
                $info.GpuNote = Get-EcoNote
                $state.GpuEcoSet = $true
                $state.GpuEcoOrig = $ecoCur
            } else {
                $info.GpuNote = 'Eco 指令被拒绝'
            }
        }
    } else {
        $info.GpuNote = 'ATK 接口不可用, 独显未切换'
    }

    $state | ConvertTo-Json | Out-File $StateFile -Encoding UTF8
    return $info
}

function Disable-ULP {
    $info = @{ RefreshRestored = 0; GpuRebootNote = $false; GpuNote = '' }

    $st = $null
    if (Test-Path $StateFile) {
        try { $st = Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $st = $null }
    }

    # ---- 1. 电源方案恢复 ----
    $csv = Join-Path $AppDir 'backup.csv'
    if (Test-Path $csv) {
        Import-Csv $csv | ForEach-Object {
            powercfg /setacvalueindex $_.scheme $_.sub $_.set ([int]$_.ac) | Out-Null
            powercfg /setdcvalueindex $_.scheme $_.sub $_.set ([int]$_.dc) | Out-Null
        }
    }

    # ---- 2. 刷新率恢复 ----
    if ($st -and $st.RefreshOrig) {
        $info.RefreshRestored = Restore-Display -Pairs @($st.RefreshOrig)
    }

    # ---- 3. 独显模式恢复 ----
    if ($st -and $st.GpuEcoSet) {
        $ecoBack = [uint32]0
        if ($st.GpuEcoOrig -ne $null) { $ecoBack = [uint32]$st.GpuEcoOrig }
        Set-AsusDevValue -DevId $GPU_ECO -Value $ecoBack | Out-Null
        # Eco=0 之后独显不一定立刻上线(G-Helper 会重启 NV 服务, 这里不碰服务), 靠重启最省事
        $info.GpuNote = 'Eco 已关闭; 若独显没回来, 重启一次'
    }
    # MUX 要不要写回, 看"现在是不是独显直连", 不看 state.json 里"这次开启动没动过":
    # 开启时如果本来就在混合模式(第一次用完之后的常态), 那个标志根本不会写,
    # 于是退出既不写回也不提示重启, 机器留在核显直连上 —— 满血性能没回来还不提示。
    $muxTarget = 0   # 0 = 独显直连
    if ($st -and $st.GpuMuxOrig -ne $null) { $muxTarget = [uint32]$st.GpuMuxOrig }
    $muxCur = Get-AsusDevValue -DevId $GPU_MUX
    if ($muxCur -ne $null -and $muxCur -ne $muxTarget) {
        if (Set-AsusDevValue -DevId $GPU_MUX -Value $muxTarget) { $info.GpuRebootNote = $true }
        else { $info.GpuNote = 'MUX 写回被拒绝, 需在奥创中心手动切回独显直连' }
    } elseif (Need-GpuReboot) {
        # 寄存器已经是独显直连, 但独显还没上电(上一次写了 MUX 之后没重启过) -> 照样要提示重启
        $info.GpuRebootNote = $true
    }

    powercfg /setactive (Get-ActiveScheme) | Out-Null
    Remove-Item $StateFile -ErrorAction SilentlyContinue
    Remove-Item $csv -ErrorAction SilentlyContinue
    return $info
}

# ---------- 静默模式: enable / disable ----------
if ($Action -eq 'enable') {
    $i = Enable-ULP
    if ($i.Already) {
        Write-Output 'ULP_ALREADY_ENABLED'
        if ($i.ReconcileNote) { Write-Output ('GPU_NOTE ' + $i.ReconcileNote) }
    } else {
        Write-Output 'ULP_ENABLED'
        if ($i.GpuReboot) { Write-Output 'GPU_REBOOT_PENDING' }
        elseif ($i.GpuDone) { Write-Output ('GPU_ECO_ON ' + $i.GpuNote) }
        else { Write-Output ('GPU_FAIL ' + $i.GpuNote) }
        if ($i.RefreshSet) { Write-Output ('REFRESH ' + $i.RefreshFrom + '->' + $i.RefreshTo) }
        if ($i.Warn) { Write-Output ('WARN ' + $i.Warn) }
    }
    exit 0
}
if ($Action -eq 'disable') {
    $d = Disable-ULP
    Write-Output 'ULP_DISABLED'
    if ($d.GpuRebootNote) { Write-Output 'GPU_REBOOT_PENDING' }
    if ($d.GpuNote) { Write-Output ('GPU_NOTE ' + $d.GpuNote) }
    if ($d.RefreshRestored -gt 0) { Write-Output ('REFRESH_RESTORED ' + $d.RefreshRestored) }
    exit 0
}

# ---------- GUI -----------
$form = New-Object System.Windows.Forms.Form
$form.Text = '超低功耗模式控制器'
$form.Size = New-Object System.Drawing.Size(460, 580)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = '超低功耗模式控制器'
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 14, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(90, 15)
$form.Controls.Add($lblTitle)

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = '当前状态'
$grp.Size = New-Object System.Drawing.Size(400, 150)
$grp.Location = New-Object System.Drawing.Point(20, 55)
$form.Controls.Add($grp)

$lblMode  = New-Object System.Windows.Forms.Label
$lblMode.Location = New-Object System.Drawing.Point(20, 28)
$lblMode.Size = New-Object System.Drawing.Size(360, 24)
$lblMode.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$grp.Controls.Add($lblMode)

$lblPower = New-Object System.Windows.Forms.Label
$lblPower.Location = New-Object System.Drawing.Point(20, 56)
$lblPower.Size = New-Object System.Drawing.Size(360, 22)
$grp.Controls.Add($lblPower)

$lblWatt  = New-Object System.Windows.Forms.Label
$lblWatt.Location = New-Object System.Drawing.Point(20, 82)
$lblWatt.Size = New-Object System.Drawing.Size(360, 22)
$grp.Controls.Add($lblWatt)

$lblLife  = New-Object System.Windows.Forms.Label
$lblLife.Location = New-Object System.Drawing.Point(20, 108)
$lblLife.Size = New-Object System.Drawing.Size(360, 22)
$grp.Controls.Add($lblLife)

$btnOn = New-Object System.Windows.Forms.Button
$btnOn.Text = '开启超低功耗模式'
$btnOn.Size = New-Object System.Drawing.Size(400, 52)
$btnOn.Location = New-Object System.Drawing.Point(20, 225)
$btnOn.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$btnOn.BackColor = [System.Drawing.Color]::LightGreen
$form.Controls.Add($btnOn)

$btnOff = New-Object System.Windows.Forms.Button
$btnOff.Text = '退出超低功耗模式 (恢复满血)'
$btnOff.Size = New-Object System.Drawing.Size(400, 52)
$btnOff.Location = New-Object System.Drawing.Point(20, 290)
$btnOff.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$btnOff.BackColor = [System.Drawing.Color]::MistyRose
$form.Controls.Add($btnOff)

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Location = New-Object System.Drawing.Point(20, 355)
$lblNote.Size = New-Object System.Drawing.Size(405, 215)
$lblNote.Text = @"
说明:
1. 开启后 CPU 锁定约 1.0GHz / 少量核心 / 禁睿频, 屏幕 20% 亮度,
   刷新率降到 60Hz, 独显断电(Eco)。省下的电以本窗口实时读数为准。
2. 参考实测(仅本机 G615LR/275HX/72.8Wh, 2026-09-27): 电池供电 13.7W、续航 5.3 小时。
   换配置会不同, 以"整机放电功率"实时读数为准。
3. 若当前为独显直连: 首次开启会请求切回混合模式, 需重启一次;
   重启后再打开本程序确认, 独显即断电。退出恢复直连同样需重启。
4. 适用于 PD 充电宝/低功率充电器供电、外出电池长续航。
"@
$form.Controls.Add($lblNote)

# 动态壁纸是最大的单项功耗(参考机型实测 24W vs 13.7W), 比 CPU 锁频+亮度+独显断电加起来还多。
# 只在它真在跑的时候提醒, 不跑就不占地方。
if (Get-Process -Name wallpaper32, wallpaper_engine -ErrorAction SilentlyContinue) {
    $lblNote.Text += "`r`n5. ⚠ Wallpaper Engine 正在运行 —— 参考机型实测多耗约 10W(24W vs 13.7W),`r`n   出门前请暂停, 这是能拿到的最大一笔。"
}

# 独显状态要调 nvidia-smi(要初始化 NVML), 每 3 秒跑一次太浪费还会污染功耗测量,
# 所以只在启动和点按钮后刷新一次, 定时 tick 复用上次的结论。
$script:needGpuReboot = $false
function Update-Status {
    param([switch]$RefreshGpu)
    if ($RefreshGpu) { $script:needGpuReboot = Need-GpuReboot }
    $on = Test-Path $StateFile
    if ($on) {
        $lblMode.Text = '● 已开启: 超低功耗模式'
        $lblMode.ForeColor = [System.Drawing.Color]::ForestGreen
        $btnOn.Enabled = $false
        $btnOff.Enabled = $true
        $btnOff.Text = '退出超低功耗模式 (恢复满血)'
    } elseif ($script:needGpuReboot) {
        # ULP 已退出但独显还锁在核显直连: 这时不许显示"正常满血", 也不许把按钮禁掉
        $lblMode.Text = '○ ULP 已退出, 但独显仍锁在核显直连'
        $lblMode.ForeColor = [System.Drawing.Color]::DarkOrange
        $btnOn.Enabled = $true
        $btnOff.Enabled = $true
        $btnOff.Text = '恢复满血性能 (需重启)'
    } else {
        $lblMode.Text = '○ 未开启: 正常满血模式'
        $lblMode.ForeColor = [System.Drawing.Color]::DimGray
        $btnOn.Enabled = $true
        $btnOff.Enabled = $false
        $btnOff.Text = '退出超低功耗模式 (恢复满血)'
    }
    try {
        $b  = Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop
        $wb = Get-CimInstance Win32_Battery -ErrorAction Stop
        if ($b.ChargeRate -gt 0) {
            $lblPower.Text = '电源: PD / 充电器供电中'
            $lblWatt.Text  = ('电池充电功率: {0} W' -f [math]::Round($b.ChargeRate/1000,1))
            # 插电时读不到放电功率, 不能报整机功耗 —— 参考实测值只写进说明区, 不冒充当前读数
            $lblLife.Text  = ('电量: {0}%  (插电时无法测整机功耗, 拔掉看放电读数)' -f $wb.EstimatedChargeRemaining)
        } elseif ($b.DischargeRate -gt 0) {
            $lblPower.Text = '电源: 电池供电'
            $lblWatt.Text  = ('整机放电功率: {0} W' -f [math]::Round($b.DischargeRate/1000,1))
            $h = if ($b.DischargeRate -gt 0) { $b.RemainingCapacity / $b.DischargeRate } else { 0 }
            $lblLife.Text  = ('电量: {0}%    预计续航: {1} 小时' -f $wb.EstimatedChargeRemaining, [math]::Round($h,1))
        } else {
            $lblPower.Text = '电源: 已接通 (未在充电)'
            $lblWatt.Text  = 'CPU 已锁频运行'
            $lblLife.Text  = ('电量: {0}%' -f $wb.EstimatedChargeRemaining)
        }
    } catch {
        $lblPower.Text = '电源状态读取失败'
        $lblWatt.Text  = ''
        $lblLife.Text  = ''
    }
}

# MUX 是硬件开关, 重启才生效。问一句要不要现在重启; 选"是"立即重启, 存盘请自己先弄好。
# 用 shutdown.exe 而不是 Restart-Computer: 后者在无桌面会话时会退化成"等用户手动重启"。
function Confirm-Reboot($why) {
    $r = [System.Windows.Forms.MessageBox]::Show($why + "`r`n`r`n确定要现在重启电脑吗? 未保存的内容会丢失。", '需要重启',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        shutdown.exe /r /t 0
        return $true
    }
    return $false
}

$btnOn.Add_Click({
    try {
        $i = Enable-ULP
        Update-Status -RefreshGpu
        if ($i.Already) {
            $m = '当前已处于超低功耗模式。'
            if ($i.ReconcileNote) { $m += "`r`n" + $i.ReconcileNote }
            [System.Windows.Forms.MessageBox]::Show($m, '已开启', 0, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $msg = '超低功耗模式已开启!' + "`r`n`r`nCPU 锁定约 1.0GHz, 屏幕 20%, 刷新率 60Hz, 独显断电。`r`n实际功耗以主窗口的实时读数为准。"
        if ($i.RefreshSet) { $msg += ("`r`n刷新率: {0}Hz → {1}Hz" -f $i.RefreshFrom, $i.RefreshTo) }
        else { $msg += "`r`n刷新率: 未变动(无更低档位)" }
        $msg += ("`r`n独显: " + $i.GpuNote)
        if ($i.Warn) { $msg += ("`r`n注意: " + $i.Warn) }
        [System.Windows.Forms.MessageBox]::Show($msg, '已开启', 0, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        if ($i.GpuReboot -and (Confirm-Reboot 'MUX 已请求切回混合模式, 重启后独显才会真正断电。')) { $form.Close() }
    } catch {
        [System.Windows.Forms.MessageBox]::Show('开启失败: ' + $_.Exception.Message, '错误', 0, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnOff.Add_Click({
    try {
        $d = Disable-ULP
        Update-Status -RefreshGpu
        $msg = '已退出超低功耗模式, 满血性能已恢复。'
        if ($d.RefreshRestored -gt 0) { $msg += ("`r`n刷新率: 已恢复 ({0} 台)" -f $d.RefreshRestored) }
        if ($d.GpuRebootNote) { $msg += "`r`n独显直连: 已请求恢复, 重启电脑后生效" }
        if ($d.GpuNote) { $msg += ("`r`n独显: " + $d.GpuNote) }
        [System.Windows.Forms.MessageBox]::Show($msg, '已恢复', 0, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        if ($d.GpuRebootNote -and (Confirm-Reboot '独显直连已请求恢复, 重启后生效。')) { $form.Close() }
    } catch {
        [System.Windows.Forms.MessageBox]::Show('退出失败: ' + $_.Exception.Message, '错误', 0, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 3000
$timer.Add_Tick({ Update-Status })
$timer.Start()

Update-Status -RefreshGpu
# 上次开启时请求了 MUX 切换的话, 重启后这次打开就把 Eco 补上, 不用再点一次"开启"
$bootNote = ''
if (Test-Path $StateFile) { $bootNote = Sync-AfterReboot }
if ($bootNote) { $lblMode.Text = '● 已开启: ' + $bootNote }
[void]$form.ShowDialog()
