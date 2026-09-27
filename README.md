# UltraLowPower — 电脑功率控制（超低功耗模式控制器）

把整机功耗压到尽可能低的电源方案控制器。**在 ASUS ROG G615LR（枪神9 / 魔霸新锐 2025）上实测 13.7W**，适用于该系列 / Windows 11。13.7W 是这台机器这一次实测的结果，不是产品标称——换配置请看 GUI 里的实时读数（见下方「适用范围」）。

## 安装

去 [Releases](../../releases) 页面下载 **`UltraLowPower-Setup.exe`**（约 53 KB，单文件），
双击即装，不需要预装任何东西。

- 需要**管理员权限**：双击后会弹一次 UAC，点「是」。
- 装到 `C:\Program Files\UltraLowPower`，同时建桌面和开始菜单快捷方式，
  并在「设置 → 应用 → 已安装的应用」里注册一项（从那里可以卸载）。
- **SmartScreen 提示**：自编译产物没有数字签名，别人机器上会弹「Windows 已保护你的电脑」，
  点 **更多信息 → 仍要运行**。这是自编译程序的正常现象。
- 卸载：开始菜单 / 桌面没有卸载入口，去「已安装的应用」点卸载，或者直接跑
  `C:\Program Files\UltraLowPower\Uninstall.exe`。**卸载时如果超低功耗模式还开着，
  卸载器会先恢复电源设置再删文件**，不会把 CPU 永久锁在 25%。

想自己从源码构建：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File installer\build.ps1
```

依赖只有 Windows 自带的 `csc.exe`（.NET Framework 编译器）和 PowerShell 5.1，
不需要装 Inno Setup / WiX / 任何第三方打包器。

> 本项目原为豆包（Doubao）聊天会话中生成的工具，2026-09-27 从本地工作区整理出来开源。
> 整理过程只改路径和打包方式，核心逻辑未动。

## 适用范围

**已在实机验证**：ASUS ROG **G615LR = 枪神9 / 魔霸新锐 2025**（Intel Core Ultra 9 275HX +
RTX 5070 Ti + 72.8Wh），Windows 11 build 26200。本 README 里所有实测数字都来自这台机器。

| 模块 | 跨机器可用性 | 原因 |
|---|---|---|
| 电源方案 15 项设置 | ✅ 任何 Win10/11 笔记本 | 子组/设置 GUID 全是微软标准（`54533251`/`bc5038f7`/`75b0ae3f`/…），方案 GUID 是 `powercfg /list` 现读的，没有硬编码 |
| 刷新率降档 | ✅ | 动态枚举可用档位，60Hz 优先、没有就退到 ≥60 的最低档 |
| 功耗/续航读数 | ✅ | 全部运行时实测（`root\wmi\BatteryStatus`），跟着机器走 |
| 电池/亮度 | ⚠️ 大概率可以 | 亮度走电源方案 `aded5e82`；个别机型只认 WMI `WmiMonitorBrightnessMethods`，那种情况读回核对会报"未生效" |
| **独显 MUX + Eco** | ❌ **仅华硕** | 走 `\\.\ATKACPI` + 控制码 `0x0022240C`，微星/联想/机械革命/雷蛇都没有这个设备节点，也没有公开等价物 |

枪神9 全系（G615LR / LW / LP / LM / JH / LH，同属 2025 G615 产品线）预期直接可用——
`0x00090016`(MUX)、`0x00090020`(Eco) 是 ASUS ATK 的**平台级 dev ID**，不是每块板独有，
G-Helper 能覆盖整个 Strix 系列正是因为这点。差异只在 CPU/独显/电池型号，会影响具体数字：

| 设置 | 本机（G615LR，24 核） | 别的配置 |
|---|---|---|
| `CPU_CORES = 8`（百分比） | → 锁 **2 核** | 16 核 → 1 核；20 核 → 2 核。省电效果和性能损失都跟着变 |
| `CPU_MAX = 25%` | 275HX 基础频率高，25% 已经在 1GHz 以下 | 频率更低的 CPU 上比例约束才是主约束 |
| `CPU_FREQ = 1000`（绝对 MHz） | 与 25% 取小，1000MHz 不生效 | 低频 CPU 上这个约束才起作用 |
| 13.7W / 5.3 小时 | 本机实测 | 大独显（5080/5090）断电后差异不大，但电池容量差几倍续航就差几倍 |

在**非华硕**机器上：CPU 锁频 + 60Hz + 省电设置照常生效，独显那一步会跳过并明说
`ATK 接口不可用, 独显未切换`（`Enable-ULP` 末段），不会假成功。

## 功能

**开启超低功耗模式**（一键完成以下全部动作）：

1. **电源方案**：对所有电源方案（含奥创自动切换的方案）同时锁定——
   CPU 最大频率 1000 MHz、最小状态 1%、最大状态 25%、只用少量核心（最大核心数 8%，本机 24 核 → 2 核）、
   禁用睿频；屏幕 20% 亮度、硬盘/显示延后关闭、核显最大续航、
   PCIe ASPM 最大省电、USB 选择性暂停、Wi-Fi 最高节能、媒体播放优化节能。
   原值从注册表 `...\Power\User\PowerSchemes\<方案>\<子组>\<设置>` 的
   `ACSettingIndex`/`DCSettingIndex` 读取（**不用 `powercfg /q`**，它的字段名是本地化的，
   换语言就解析失败 → 改了设置却没进 `backup.csv` → 退出恢复不回去）。
   写完把生效方案的 15 项**读回核对**，对不上的会在提示框里点名哪几项没生效
   （`powercfg` 对隐藏项会 exit 0 却什么都不写，不核对只能等下次重启才发现）。
2. **刷新率 → 60Hz**：枚举每台活动显示器的可用档位（实机：60/48/30/240/120/100），
   优先选 60Hz，其次 ≥60 的最低档；先 CDS_TEST 验证再应用。原值记入 `state.json`，退出还原。
3. **独显 → 核显模式**：走 `\\.\ATKACPI` 接口（G-Helper 同款，实机验证可读可写）。
   实测本机语义（与 G-Helper 源码一致）：**MUX `0x00090016` 0=独显直连 / 1=混合**，
   **Eco `0x00090020` 1=独显断电（混合模式下实时生效）**。
   若当前是独显直连：写 MUX=1 + Eco=1，**重启一次生效**；重启后**重新打开本程序即自动补完 Eco**
   （不用再点一次"开启"）。写完 Eco 会用 `nvidia-smi --query-gpu=power.draw` **实测独显功耗**：
   读不到 = 真断电，仍 >1W 则如实报"有程序在用独显"，不再只信 ATK 的返回值。
   退出恢复**看硬件实际状态**，不只看 `state.json`：只要 MUX 寄存器不是 0（还是混合），
   或寄存器说直连但 `nvidia-smi` 读不到瓦数（独显还没上电），就写回 MUX=0 并弹确认框，
   点确认后立即重启。写回被驱动拒绝会明说"需在奥创中心手动切"，不假装成功。
   状态栏因此有三态：已开启 / **ULP 已退出但独显仍锁在核显直连**（橙色，"恢复满血"仍可点）/ 真满血。
4. ~~**键盘灯光 → 关闭**~~ —— **已移除**（2026-09-27，见下方「已放弃的功能」）。

**退出**：从 `backup.csv` 逐项恢复电源设置（含交流/电池两套索引），
并还原刷新率、独显模式，完整回到开启前状态。

已开启状态下再次点击"开启"会被拒绝（防止把已锁定的值当作原始值备份）。

GUI 每 3 秒刷新电池充放电功率与预计续航。

## 已放弃的功能

### 键盘灯光关闭（2026-09-27 删除，代码已全部移除）

原本是第 4 项功能：向键盘的 HID **Feature 报文** `[5A BA C5 C4 亮度]`（G-Helper 的 SetFeature
方式）下发亮度 0，并暂停 AURA 灯效服务。**功能已从代码中完全删除**（`$HidCs` C# 块 182 行、
`Set-KeyboardLight`、`Stop-LightSvcPersist`、`state.json` 的 4 个键盘字段、GUI/CLI 输出、
`.hid_target.ps1` 自检脚本）。

删除原因——**"重启后自动关灯"这个目标做不到**，实测结论：

| 验证项 | 结果 |
|---|---|
| 停 `LightingService` + 改启动类型 `Manual`，重启后服务是否还自己起来 | ❌ 不会，确实保持 `Stopped / Manual` |
| 重启后打开本程序，`Sync-AfterReboot` 补写亮度 0 | ✅ 执行了 |
| 键盘灯实际状态 | ❌ **仍然亮** |

也就是说 `LightingService` **不是**开机点灯的那个：开机时是**固件**用上次保存的档位点亮的，
Windows 侧没有任何东西去关它。本程序只有"被打开时"才有机会写一次，所以
「重启后不打开程序也自动灭」缺的不是修 bug，而是缺一个**开机就执行的执行体**
（需要注册 SYSTEM 计划任务，属于新机制，且 SYSTEM 上下文能否写通键盘 HID 未验证）。
为了让约 1W（占实测 13.7W 的 7%）背光功耗引入这套机制不划算，故删除。

> 期间踩过的两个坑，已随代码一起消失：① 原启动类型只在 `Automatic` 时记录，导致服务永久卡在
> `Manual`、之后每轮都还原不回去；② 退出时先写亮度后启服务，顺序反了会被服务配置覆盖。

## 目录结构

```
UltraLowPower/
├─ app/                            ← 主程序
│  ├─ UltraLowPower.ps1             控制器本体（PowerShell + WinForms）
│  ├─ UltraLowPowerLauncher.cs      启动器源码（编译出下面的 exe）
│  ├─ UltraLowPower.exe             启动器（无控制台窗口，双击它；由 build.ps1 生成）
│  ├─ start-ulp.bat                 备用入口：exe 被杀软隔离时用，能在命令行看到报错
│  ├─ (运行时生成) state.json       开启状态 + 刷新率/独显还原信息
│  └─ (运行时生成) backup.csv       开启前全部电源设置的备份
├─ installer/                     ← 打包成安装包用
│  ├─ build.ps1                     构建脚本，产出 dist\ 下的两个 exe
│  ├─ Setup.cs                      安装/卸载向导源码（同一份，编两次）
│  ├─ install.ps1                   提权后运行：拷文件、建快捷方式、注册卸载项
│  └─ uninstall.ps1                 卸载：先恢复电源设置，再删干净
├─ dist/                          ← 编译产物，不入库（Releases 页放的是这里那个 exe）
│  ├─ UltraLowPower-Setup.exe       ← 分发给别人的那一个文件（53 KB）
│  └─ Uninstall.exe                  随安装包一起装到安装目录（17 KB）
├─ .gitignore
├─ .verify.ps1                     改动后必跑：BOM 修正 + PS 解析 + 内嵌 C# 块编译
└─ README.md
```

> 目录和文件名一律用 ASCII/英文（`app` 早先叫 `超低功耗模式`、启动器早先叫
> `启动超低功耗模式.bat`）。原因：`.bat` 里 `Start-Process -FilePath '%~f0'` 要把
> 自身路径过一遍 cmd 的 OEM 代码页，路径含中文时换台机器或换系统语言就可能找不到自己。
> 界面上的中文是显示文本，不受影响。

### exe 启动器

`UltraLowPower.exe` 让整个程序表现为一个常规 Windows 应用程序：**只有控制器那一个
GUI 窗口，双击不闪黑窗口**。做法是编译成 `winexe`（PE Subsystem=2）而不是控制台程序，
启动 PowerShell 时带 `CreateNoWindow=true`；exe 自己先提权，ps1 检测到已是管理员就
跳过自己的提权（`UltraLowPower.ps1` 第 18-22 行），所以**只会有一次 UAC 提示**。

exe 和 ps1 是两个文件、并列放在 `app\`（exe 靠自身目录找 ps1）。这样 ps1 保持可编辑，
改完不用重新编译 exe。改 `UltraLowPowerLauncher.cs` 后重新编译（不需要装任何东西，
`csc` 是 Windows 自带的 .NET Framework 编译器）：

```powershell
cd app
csc /nologo /target:winexe /optimize+ /out:UltraLowPower.exe `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll UltraLowPowerLauncher.cs
```

> 2026-09-27 删除了 `ULPLauncher/`（把 ps1 以字节数组内嵌、想打成单文件 exe 的 C# 工程）。
> 它的 `System.Management.Automation` 引用指向 MSI 版 PowerShell 7 布局，本机是 MSIX 版，
> 本来就 `dotnet build` 失败；内嵌的 ps1 副本也已长期落后于主程序。现在的
> `app\UltraLowPowerLauncher.cs` 是重写的极简版，只用 `csc` 编译，不依赖 PowerShell SDK。

## 安装包（给别人用）

`dist\UltraLowPower-Setup.exe` 是**单个文件**，53 KB，双击即装，**不需要装任何东西**。
拷到任何目录都能直接双击运行，唯一要求是管理员权限（双击后会弹一次 UAC，点「是」）。
装完会得到：默认路径 `C:\Program Files\UltraLowPower`、桌面 + 开始菜单快捷方式、
以及「设置 → 应用 → 已安装的应用」里的一项（从那里一键卸载）。

### 界面

安装和卸载都是**三页向导**（WinForms，`/target:winexe`，不闪黑窗口）：

1. 说明页 —— 装的话写清会改电源方案/亮度/刷新率/独显模式，卸载的话说明会先恢复电源设置
2. 进度页 —— 实时滚动 `install.ps1` / `uninstall.ps1` 的输出，**这一页把翻页按钮藏了**，
   免得用户在安装没跑完时直接跳到完成页
3. 完成页 —— 只有「完成」和「关闭」两个按钮（完成页不出现「上一步」，回去只会落到
   已经禁用掉按钮的进度页，是个死胡同）

完成页默认勾选「安装完成后立即启动 UltraLowPower」。

### SmartScreen 会拦一下

自编译产物必然没有数字签名，别人机器上双击会弹「Windows 已保护你的电脑」。
点 **更多信息 → 仍要运行**。这是没签名的自编译程序的正常现象，不是程序有问题。

### 重新构建

`app\` 或 `installer\` 改完都要重跑：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File installer\build.ps1
```

一次编出安装向导、卸载向导、主程序启动器，打 zip，再把 zip 嵌回安装向导。

打进包里的只有 8 个文件：`UltraLowPower.exe` / `.ps1` / `Launcher.cs` / `start-ulp.bat` /
`README.md` / `install.ps1` / `uninstall.ps1` / `Uninstall.exe`。**不含** `.verify.ps1`（开发自检）、
`.diag*`（已废弃的诊断）、`.ref_GPUMode.cs`（参考副本）、`Silent_PowerScheme_Backup.reg`
（装机当时的本机快照，对别人没意义）。

自己写 SFX 而不用现成打包器，两个原因：

- **IExpress 不可用**：这个 Windows 11 build 26100 上没有 `wibext.dll`（IExpress 的打包
  引擎），最小样例都 `exit 1`。
- **Inno Setup 装不上**：官网 CDN（`files.jrsoftware.org`）连不通，GitHub Releases
  实测 ≈1.2 KB/s，10 MB 拉了 10 分钟没完。

所以 `installer\Setup.cs` 用 .NET 自带的 `System.IO.Compression` 解内嵌 zip，用 Windows
自带的 `csc.exe` 编译，**零外部依赖**。同一份源码编两次，`/define:UNINSTALLER` 切换
安装模式 / 卸载模式，得到 `UltraLowPower-Setup.exe`（内嵌 payload zip）和 `Uninstall.exe`
（进安装目录，控制面板的卸载项指向它）。两个都是 winexe，用户只看到向导那一个窗口。

### 卸载时最要紧的一件事

`uninstall.ps1` 删任何东西之前，先看 `state.json` 或 `backup.csv` 在不在：

- 两者都不在 → 从没开过 ULP，直接删。
- 任一在 → 先跑 `UltraLowPower.ps1 -Action disable` **恢复电源设置**，再删。

理由：`backup.csv` 存着 15 项设置 × 6 个电源方案的原值，是把 CPU 从锁 25% 解回来的
唯一数据，删掉就再也回不去了。判据同时认 `backup.csv` 是为了覆盖"开启过程中崩在写
`state.json` 之前"这种只剩 `backup.csv` 的半途状态——那恰恰最需要恢复。

> 已知边界：卸载器删注册表卸载项时不限定安装目录，所以在**测试**里对着一份拷贝跑卸载，
> 会把本机真实安装的卸载项一起删掉。正常使用只有一份安装，不受影响。

> 目录删除要靠"延时进程"：脚本和卸载器 exe 自己都在这个目录里跑，删不掉自己。
> `uninstall.ps1` 丢一个 `ping -n 4 … & rmdir /s /q … & ping -n 2 … & rmdir /s /q …`
> 的后台 cmd，等 exe 退出后删两遍（第一遍 exe 还占着 `Uninstall.exe`，会留个空目录）。
> 安装向导的临时目录同理，靠 `Setup.cs` 的 `RemoveDirLater` 清。测残留要等 ≥8 秒：
> 两次 rmdir 加起来约 4~5 秒才跑完。

## 使用方法

装好后双击桌面上的 `UltraLowPower.lnk`（或开始菜单里的同名项），UAC 弹窗点"是"即可。

命令行方式（管理员）：

```powershell
cd "C:\Program Files\UltraLowPower"
powershell -NoProfile -ExecutionPolicy Bypass -File UltraLowPower.ps1 -Action enable   # 开启
powershell -NoProfile -ExecutionPolicy Bypass -File UltraLowPower.ps1 -Action disable  # 退出并恢复
```

从源码跑（不安装）：

```powershell
cd app
powershell -NoProfile -ExecutionPolicy Bypass -File UltraLowPower.ps1 -Action enable
```

## 注意事项

1. 开启期间启动游戏或调用独显的软件会把独显唤醒，导致功耗超标。
2. `backup.csv` 是电源恢复的唯一依据、`state.json` 记录其余还原信息——
   **都不要手动删除或改动**（正常点"退出"会自动清除）。
3. 脚本与 `.bat` 必须保持同目录（`.bat` 用 `%~dp0` 定位脚本；运行时状态文件也写在脚本目录）。
4. **独显直连 ↔ 混合是 MUX 硬件开关，必须重启生效**（Armoury Crate / G-Helper 行为相同）。
   当前处于独显直连时：开启 → 重启一次 → 重开本程序（自动补 Eco，标题栏会显示结果）；
   退出恢复直连 → 再重启一次。
5. 本机（G615LR）实测：root\wmi 无任何 Asus WMI 类，ATK 只能走 `\\.\ATKACPI` 设备通道
   （已验证 INIT/DSTS/DEVS 全部可用）；别的机型若 ATKACPI 打不开，独显控制会不可用
   （电源方案与刷新率不受影响）。
6. Armoury Crate 全家服务（ASUSOptimization 等）与本工具并存，互不干扰。
7. **有两件事会被重启作废**，重新打开本程序时自动补齐（`Sync-AfterReboot`）：
   - MUX 切换要重启才生效 → 补写 Eco；
   - CPU 最大频率 / 最大核心数 enable 时写入成功，但重启后被 ASUS 性能配置写回
     `0/0` 和 `100/100` → 对**所有**方案补写（只补当前方案会漏，因为拔电时
     Armoury Crate 会自动切到 Silent，那个方案就变成放开的）。
   不打开本程序 = 补不上。
8. **整机功耗实测**（2026-09-27，电池供电下读 `root\wmi\BatteryStatus.DischargeRate`；
   电池 72.8Wh / `BatteryFullChargedCapacity`，0 循环）：

   | 条件 | 读数 | 续航 |
   |---|---|---|
   | **动态壁纸关闭，空闲** | **13.60 ~ 13.78W，均值 13.7W**（18 个采样点） | **5.3 小时** |
   | 动态壁纸开启（Wallpaper Engine 占 56% CPU） | 23.6 ~ 26.7W，均值 24W | 3.0 小时 |

   两次都是同一套 ULP 设置，**差值约 10W 全部来自动态壁纸**——它同时吃 CPU 和 iGPU，
   在 2560×1600 上跑动画的代价远大于 CPU 占用数字看起来的那部分。
   **要拿到接近 13.7W 的续航，必须关掉动态壁纸**；这是本机唯一的大单项，
   比 CPU 锁频、屏幕亮度、独显断电加起来的影响都大。
   另：2560×1600 面板在 20% 亮度下本身约 5~8W，允许息屏还能再省一截。
9. `backup.csv` / `state.json` 写在**脚本所在目录**：搬动或重命名项目目录就等于丢掉还原依据。
   （本次迁移就踩过：ULP 跑过一次没关掉、目录迁移后备份丢失，6 个方案的 CPU 被锁在 25%，
   只能手动恢复。）

## 已知问题

- **续航高度依赖动态壁纸**：同一套设置下，开着 Wallpaper Engine 是 24W / 3.0 小时，
  关掉是 13.7W / 5.3 小时（见「注意事项」8）。本工具管不到动态壁纸，
  出门前手动关掉是性价比最高的一步。
- exe 依赖同目录的 `UltraLowPower.ps1`（不是单文件）：把 `app\` 整个目录一起搬，
  只拷 exe 会报"找不到控制器脚本"。原 `ULPLauncher/`（ps1 以字节数组内嵌的单文件方案）
  已于 2026-09-27 删除，理由见「目录结构」下方说明。
- **exe 可能被 Windows Defender 隔离**：它是自制的、无签名的 32 位程序。
  被拦的话用 `app\start-ulp.bat` 启动，或把 `app\` 加进排除项。
