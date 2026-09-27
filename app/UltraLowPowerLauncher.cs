// 编译成无控制台窗口的 exe, 让整个程序表现为一个常规 Windows 应用程序:
//   双击 -> UAC 提权 -> 只有控制器那一个 GUI 窗口, 没有黑色命令行窗口。
// ps1 已是管理员时不会再自己提权(见 UltraLowPower.ps1 第 18-22 行), 所以只会有一次 UAC。
//
// 重新编译(不需要装任何东西, csc 是 Windows 自带的 .NET Framework 编译器):
//   csc /nologo /target:winexe /optimize+ /out:UltraLowPower.exe ^
//       /r:System.Windows.Forms.dll /r:System.Drawing.dll UltraLowPowerLauncher.cs
//
// exe 必须和 UltraLowPower.ps1 在同一目录(靠 GetExeDir 定位)。
// 编译产物是 x64/x86 无关的(AnyCPU), 换机器不用重编。
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

class UltraLowPowerLauncher
{
    static string GetExeDir()
    {
        try
        {
            return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        }
        catch
        {
            return Environment.CurrentDirectory;
        }
    }

    static bool IsAdmin()
    {
        try
        {
            return new WindowsPrincipal(WindowsIdentity.GetCurrent())
                .IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    [STAThread]
    static int Main()
    {
        if (!IsAdmin())
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = Process.GetCurrentProcess().MainModule.FileName,
                    UseShellExecute = true,
                    Verb = "runas"
                });
            }
            catch (Exception ex)
            {
                MessageBox.Show("UAC 提权失败:\n" + ex.Message, "UltraLowPower",
                    MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            return 0;   // 用户在 UAC 上点"否", 正常退出
        }

        string ps1 = Path.Combine(GetExeDir(), "UltraLowPower.ps1");
        if (!File.Exists(ps1))
        {
            MessageBox.Show(
                "找不到控制器脚本:\n" + ps1 + "\n\n请确保 UltraLowPower.ps1 与 UltraLowPower.exe 在同一目录。",
                "UltraLowPower", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }

        try
        {
            Process proc = Process.Start(new ProcessStartInfo
            {
                FileName = "powershell.exe",
                // CreateNoWindow: 不给 PowerShell 分配可见控制台, 这是"只有一个窗口"的关键
                Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + ps1 + "\" -Action gui",
                UseShellExecute = false,
                CreateNoWindow = true
            });
            proc.WaitForExit();

            // 正常情况下 GUI 是 ps1 里的, 这个 exe 自己不显示任何窗口。
            // 万一 ps1 崩了, 不加这段的话用户只看到"双击了但什么都没发生", 没法排查。
            if (proc.ExitCode != 0)
            {
                MessageBox.Show(
                    "控制器异常退出, 退出代码 " + proc.ExitCode + "。\n\n" +
                    "改用同目录的 start-ulp.bat 启动, 可以在命令行里看到错误信息。",
                    "UltraLowPower", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            return proc.ExitCode;
        }
        catch (Exception ex)
        {
            MessageBox.Show("启动 PowerShell 失败:\n" + ex.Message, "UltraLowPower",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
