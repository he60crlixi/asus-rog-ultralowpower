// UltraLowPower 安装/卸载向导
//
// 同一个文件编译成两个 exe, 用 /define:UNINSTALLER 区分:
//   dist\UltraLowPower-Setup.exe   安装向导 (内嵌 payload zip, 解包后装)
//   安装目录\Uninstall.exe         卸载向导 (不装东西, 只跑同目录的 uninstall.ps1)
//
// 为什么自己写而不用现成打包器:
//   - IExpress: 这个 Windows 11 build 26100 上没有 wibext.dll (打包引擎), 最小样例都 exit 1
//   - Inno Setup / NSIS: 要另外下载安装, 本机网络拉不到 (实测 1.2 KB/s)
//   - .NET 自带 System.IO.Compression + 自带 csc.exe: 都在, 直接用, 零外部依赖
//
// 实际的安装/卸载动作在 install.ps1 / uninstall.ps1 里, 这个 exe 只管界面和提权。
// 两个都编成 /target:winexe, 所以除了向导窗口和一次 UAC, 不会闪出黑窗口。

using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;

static class Build
{
    // 用 static readonly 而不是 const: const 会被编译器折叠, 编安装向导时
    // DefaultUninstall=false 变成 if(false), 整句被判成不可达代码 (warning CS0162)
#if UNINSTALLER
    public static readonly bool DefaultUninstall = true;
#else
    public static readonly bool DefaultUninstall = false;
#endif
}

class Setup
{
    const string ResourceName = "SfxPayload.zip";
    public const string AppName = "UltraLowPower";
    static bool uninstallMode;
    public static bool quiet;
    public static string tempDir;

    [STAThread]
    static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        foreach (string a in args)
        {
            if (a.Equals("-uninstall", StringComparison.OrdinalIgnoreCase)) uninstallMode = true;
            else if (a.Equals("-quiet", StringComparison.OrdinalIgnoreCase)) quiet = true;
        }
        if (Build.DefaultUninstall) uninstallMode = true;

        // 装到 Program Files、写 HKLM 卸载项都要管理员。
        // 提权后的进程是分离的, 拿不到这里的退出码, 所以直接退出, 由新进程从头再跑一遍。
        if (!IsAdmin())
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = Process.GetCurrentProcess().MainModule.FileName,
                    UseShellExecute = true,
                    Verb = "runas",
                    Arguments = string.Join(" ", args)
                });
            }
            catch (System.ComponentModel.Win32Exception)
            {
                // 用户在 UAC 上点了"否"
            }
            return 0;
        }

        try
        {
            if (uninstallMode)
            {
                Application.Run(new UninstallForm());
            }
            else
            {
                tempDir = Extract();
                Application.Run(new InstallForm());
            }
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, AppName, MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    static bool IsAdmin()
    {
        try
        {
            return new WindowsPrincipal(WindowsIdentity.GetCurrent())
                .IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }

    /// <summary>把内嵌的 payload zip 解到临时目录, 返回该目录。</summary>
    static string Extract()
    {
        string dir = Path.Combine(Path.GetTempPath(),
            "UltraLowPowerSetup_" + Process.GetCurrentProcess().Id);
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
        Directory.CreateDirectory(dir);

        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(ResourceName))
        {
            if (s == null) throw new Exception("安装包已损坏: 找不到内嵌的 payload。");
            using (var zip = new ZipArchive(s, ZipArchiveMode.Read))
            {
                foreach (ZipArchiveEntry e in zip.Entries)
                {
                    string outPath = Path.Combine(dir, e.FullName);
                    if (e.FullName.EndsWith("/")) { Directory.CreateDirectory(outPath); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(outPath));
                    e.ExtractToFile(outPath, true);
                }
            }
        }
        if (!File.Exists(Path.Combine(dir, "install.ps1")))
            throw new Exception("安装包已损坏: 缺少 install.ps1。");
        return dir;
    }

    /// <summary>
    /// 跑一个 ps1, 实时把它的输出写进 log 文本框。
    /// CreateNoWindow=true: 这个进程是 winexe, 唯一的界面是向导本身。
    /// </summary>
    public static void RunScript(string script, string extraArgs, TextBox log, Action<int> done)
    {
        var psi = new ProcessStartInfo("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\"" + extraArgs);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;

        Process p = Process.Start(psi);
        if (p == null) { done(1); return; }

        p.OutputDataReceived += delegate (object s, DataReceivedEventArgs e)
        { if (e.Data != null) Log(log, e.Data); };
        p.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e)
        { if (e.Data != null) Log(log, "! " + e.Data); };
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();

        // 必须 .Start()。少了它这个 Thread 根本没跑, done 永远不会被调用,
        // 结果是安装确实装完了、日志也显示"安装完成", 但向导卡在进度页, 没有"完成"按钮。
        new Thread(delegate ()
        {
            p.WaitForExit();
            // 异步读取的回调比进程退出稍晚, 这里多等一下, 免得最后几行丢失
            p.WaitForExit();
            Thread.Sleep(150);
            int code = p.ExitCode;
            Control c = log;
            if (c != null && c.IsHandleCreated)
                c.BeginInvoke(new Action(delegate () { done(code); }));
        }) { IsBackground = true }.Start();
    }    static void Log(TextBox box, string line)
    {
        if (box == null) return;
        Control c = box;
        if (!c.IsHandleCreated) return;
        c.BeginInvoke(new Action(delegate ()
        {
            box.AppendText(line + Environment.NewLine);
            box.SelectionStart = box.TextLength;
            box.ScrollToCaret();
        }));
    }

    /// <summary>
    /// 延时删除一个目录。目录里可能还有正在运行的自己(exe)或脚本, 直接删会失败,
    /// 所以丢一个独立进程等几秒再删。
    /// </summary>
    public static void RemoveDirLater(string dir)
    {
        if (string.IsNullOrEmpty(dir)) return;
        try
        {
            // 必须用 UseShellExecute=true: 这个进程是 winexe, 没有控制台, 标准句柄是无效的。
            // 用 UseShellExecute=false + CreateNoWindow=true 启的 cmd 会继承到那些无效句柄,
            // 然后直接死掉, 目录永远删不掉 (实测踩过)。
            Process.Start(new ProcessStartInfo("cmd.exe",
                "/c ping -n 4 127.0.0.1 >nul & rmdir /s /q \"" + dir + "\" & rmdir /s /q \"" + dir + "\"")
            {
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            });
        }
        catch { }
    }
}

// ---------------------------------------------------------------- 向导框架

class WizardForm : Form
{
    protected Panel[] page;
    protected int cur;
    protected Button btnBack, btnNext, btnCancel;
    protected ProgressBar bar;
    protected TextBox logBox;
    Label head;
    Label sub;
    int progressIndex = -1;   // "正在干活"那一页的序号; 在这页上不给翻页按钮

    public WizardForm(string title, int pageCount)
    {
        Text = title;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(490, 350);
        Font = new Font("Microsoft YaHei UI", 9F);

        page = new Panel[pageCount];
        for (int i = 0; i < pageCount; i++)
        {
            page[i] = new Panel { Bounds = new Rectangle(20, 78, 450, 190), Visible = false };
            Controls.Add(page[i]);
        }

        head = new Label
        {
            Bounds = new Rectangle(20, 20, 450, 30),
            Font = new Font("Microsoft YaHei UI", 13F, FontStyle.Bold),
            ForeColor = Color.FromArgb(0, 78, 152),
            TextAlign = ContentAlignment.MiddleLeft
        };
        Controls.Add(head);

        sub = new Label
        {
            Bounds = new Rectangle(20, 47, 450, 20),
            ForeColor = Color.DimGray,
            TextAlign = ContentAlignment.MiddleLeft
        };
        Controls.Add(sub);

        btnBack = new Button { Bounds = new Rectangle(252, 300, 85, 28), Text = "上一步" };
        btnNext = new Button { Bounds = new Rectangle(342, 300, 85, 28), Text = "下一步" };
        btnCancel = new Button { Bounds = new Rectangle(430, 300, 40, 28), Text = "取消" };
        btnNext.Click += delegate { Next(); };
        btnBack.Click += delegate { Go(cur - 1); };
        btnCancel.Click += delegate { Cancel(); };
        Controls.Add(btnBack);
        Controls.Add(btnNext);
        Controls.Add(btnCancel);
        AcceptButton = btnNext;
        CancelButton = btnCancel;
    }

    /// <summary>切页。page 0 隐藏"上一步", 最后一页把"下一步"变成"完成"。</summary>
    protected void Go(int i)
    {
        if (i < 0 || i >= page.Length) return;
        if (cur >= 0 && cur < page.Length) page[cur].Visible = false;
        cur = i;
        page[cur].Visible = true;
        // 干活那一页把翻页按钮全藏了: 否则用户能在安装还没跑完时直接跳到完成页
        bool busy = (i == progressIndex);
        bool last = (i == page.Length - 1);
        // 完成页也不留"上一步": 点回去只会回到进度页, 而那页的取消已被禁用, 是个死胡同
        btnBack.Visible = cur > 0 && !busy && !last;
        btnNext.Visible = !busy;
        btnNext.Text = last ? "完成" : "下一步";
        if (last) btnCancel.Text = "关闭";
        OnPageShown(cur);
    }

    protected virtual void OnPageShown(int i) { }

    protected virtual void Next()
    {
        if (cur == page.Length - 1) { Finish(); return; }
        if (!ValidatePage(cur)) return;
        Go(cur + 1);
    }

    /// <summary>翻页前的校验。返回 false 表示留在本页。</summary>
    protected virtual bool ValidatePage(int i) { return true; }

    protected virtual void Finish() { Close(); }
    protected virtual void Cancel() { Close(); }

    protected void SetHead(string title, string note)
    {
        head.Text = title;
        sub.Text = note ?? "";
    }

    /// <summary>做"正在干活"那一页: 进度条 + 实时输出框。干活期间不给翻页。</summary>
    protected void MakeProgressPage(int index, string title, string note)
    {
        progressIndex = index;
        SetHead(title, note);
        bar = new ProgressBar
        {
            Bounds = new Rectangle(20, 8, 400, 18),
            Style = ProgressBarStyle.Marquee,
            MarqueeAnimationSpeed = 30
        };
        page[index].Controls.Add(bar);

        logBox = new TextBox
        {
            Bounds = new Rectangle(20, 34, 410, 145),
            Multiline = true,
            ReadOnly = true,
            ScrollBars = ScrollBars.Vertical,
            Font = new Font("Consolas", 8.5F),
            BackColor = Color.White
        };
        page[index].Controls.Add(logBox);
    }
}

// ---------------------------------------------------------------- 安装向导

class InstallForm : WizardForm
{
    TextBox pathBox;
    CheckBox runBox;
    string src;              // 解包出来的临时目录
    string installDir;
    bool running;

    public InstallForm()
        : base("安装 " + Setup.AppName, 3)
    {
        src = Setup.tempDir;

        // ---- 第 1 页: 欢迎 + 选路径 ----
        page[0].Controls.Add(new Label
        {
            Bounds = new Rectangle(0, 0, 450, 76),
            Text = "将把超低功耗模式控制器安装到本机。\r\n\r\n" +
                   "安装程序会修改电源方案、屏幕亮度、刷新率和独显模式，\r\n" +
                   "这些都可以随时用「恢复满血性能」改回来。\r\n\r\n" +
                   "需要管理员权限。",
            ForeColor = Color.FromArgb(40, 40, 40)
        });
        page[0].Controls.Add(new Label
        {
            Bounds = new Rectangle(0, 84, 100, 20),
            Text = "目标文件夹:"
        });
        pathBox = new TextBox
        {
            Bounds = new Rectangle(0, 104, 340, 23),
            Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                                Setup.AppName)
        };
        page[0].Controls.Add(pathBox);
        var browse = new Button { Bounds = new Rectangle(348, 103, 78, 25), Text = "浏览..." };
        browse.Click += delegate
        {
            using (var dlg = new FolderBrowserDialog())
            {
                dlg.Description = "选择安装文件夹";
                if (dlg.ShowDialog(this) == DialogResult.OK) pathBox.Text = dlg.SelectedPath;
            }
        };
        page[0].Controls.Add(browse);
        page[0].Controls.Add(new Label
        {
            Bounds = new Rectangle(0, 132, 450, 18),
            Text = "保持默认即可, 直接点「下一步」。",
            ForeColor = Color.DimGray
        });

        // ---- 第 2 页: 安装中 (MakeProgressPage 填内容) ----
        MakeProgressPage(1, "正在安装", "请不要关闭此窗口。");

        // ---- 第 3 页: 完成 ----
        var ok = new Label
        {
            Bounds = new Rectangle(0, 0, 30, 30),
            Text = "✓",
            Font = new Font("Segoe UI", 20F, FontStyle.Bold),
            ForeColor = Color.FromArgb(0, 130, 70)
        };
        page[2].Controls.Add(ok);
        page[2].Controls.Add(new Label
        {
            Bounds = new Rectangle(38, 4, 400, 60),
            Text = "安装完成。\r\n\r\n" +
                   "桌面和开始菜单已建立快捷方式。\r\n" +
                   "以后从「设置 → 应用 → 已安装的应用」里可以卸载。",
            ForeColor = Color.FromArgb(40, 40, 40)
        });
        runBox = new CheckBox
        {
            Bounds = new Rectangle(38, 76, 300, 22),
            Text = "立即启动 " + Setup.AppName,
            Checked = true
        };
        page[2].Controls.Add(runBox);

        Go(0);
    }

    protected override void OnPageShown(int i)
    {
        if (i == 0) { SetHead("安装 " + Setup.AppName, "超低功耗模式控制器"); }
    }

    protected override bool ValidatePage(int i)
    {
        if (i != 0) return true;
        string p = pathBox.Text.Trim();
        if (p.Length == 0)
        {
            MessageBox.Show("请填写安装文件夹。", Setup.AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        try
        {
            // 提前验一遍路径, 别等装到一半才失败
            if (File.Exists(p))
                throw new Exception("这个位置是个文件, 不是文件夹。");
            if (!Directory.Exists(p)) Directory.CreateDirectory(p);
            p = Path.GetFullPath(p);
        }
        catch (Exception ex)
        {
            MessageBox.Show("这个文件夹不能用: " + ex.Message, Setup.AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
        pathBox.Text = p;
        return true;
    }

    protected override void Next()
    {
        if (cur == 0)
        {
            if (!ValidatePage(0)) return;
            installDir = pathBox.Text.Trim();
            running = true;
            Go(1);
            // 干活期间不给取消: 中途掐断会留下装一半的目录和半套快捷方式
            btnCancel.Enabled = false;
            btnCancel.Text = "安装中";
            Setup.RunScript(Path.Combine(src, "install.ps1"),
                " -Path \"" + installDir + "\" -Silent", logBox, OnScriptExit);
            return;
        }
        base.Next();
    }

    void OnScriptExit(int code)
    {
        running = false;
        if (code != 0)
        {
            btnCancel.Enabled = true;
            btnCancel.Text = "关闭";
            SetHead("安装失败", "错误码 " + code);
            MessageBox.Show("安装没有成功, 详细信息见上面的输出。\r\n\r\n" +
                            "关闭本窗口后再重新运行安装包。", Setup.AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        Go(2);
    }

    protected override void Finish()
    {
        // 释放解包出来的临时目录 (里面没有正在运行的东西了, 但保险起见走延时删除)
        Setup.RemoveDirLater(Setup.tempDir);
        Setup.tempDir = null;

        if (runBox.Checked)
        {
            try
            {
                Process.Start(new ProcessStartInfo(
                    Path.Combine(installDir, Setup.AppName + ".exe")) { UseShellExecute = true });
            }
            catch { }
        }
        Close();
    }

    protected override void Cancel()
    {
        if (running) return;   // 安装中: 忽略
        Setup.RemoveDirLater(Setup.tempDir);
        Close();
    }
}

// ---------------------------------------------------------------- 卸载向导

class UninstallForm : WizardForm
{
    bool running;

    public UninstallForm()
        : base("卸载 " + Setup.AppName, 3)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;

        // ---- 第 1 页: 确认 ----
        page[0].Controls.Add(new Label
        {
            Bounds = new Rectangle(0, 0, 450, 100),
            Text = "即将从本机移除超低功耗模式控制器。\r\n\r\n" +
                   "程序文件和快捷方式会被删除，电源方案、亮度、刷新率\r\n" +
                   "不属于本程序，会保持现在的状态。\r\n\r\n" +
                   "如果超低功耗模式还开着，卸载程序会先把它关掉、\r\n" +
                   "恢复电源设置，再删除文件。",
            ForeColor = Color.FromArgb(40, 40, 40)
        });
        page[0].Controls.Add(new Label
        {
            Bounds = new Rectangle(0, 116, 450, 20),
            Text = "安装位置: " + dir,
            ForeColor = Color.DimGray
        });

        // ---- 第 2 页: 卸载中 ----
        MakeProgressPage(1, "正在卸载", "请不要关闭此窗口。");

        // ---- 第 3 页: 完成 ----
        page[2].Controls.Add(new Label
        {
            Bounds = new Rectangle(0, 0, 30, 30),
            Text = "✓",
            Font = new Font("Segoe UI", 20F, FontStyle.Bold),
            ForeColor = Color.FromArgb(0, 130, 70)
        });
        page[2].Controls.Add(new Label
        {
            Bounds = new Rectangle(38, 4, 400, 80),
            Text = "卸载完成。\r\n\r\n" +
                   "如果刚才提示电源设置恢复失败，请重新安装一次\r\n" +
                   "再卸载，或手动把电源方案里的\r\n" +
                   "「最大处理器状态」改回 100%。",
            ForeColor = Color.FromArgb(40, 40, 40)
        });

        Go(0);
    }

    protected override void OnPageShown(int i)
    {
        if (i == 0) SetHead("卸载 " + Setup.AppName, "超低功耗模式控制器");
        if (i == 2) SetHead("卸载完成", "文件已全部删除。");
    }

    protected override void Next()
    {
        if (cur == 0)
        {
            running = true;
            Go(1);
            btnCancel.Enabled = false;
            btnCancel.Text = "卸载中";
            Setup.RunScript(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "uninstall.ps1"),
                "", logBox, OnScriptExit);
            return;
        }
        base.Next();
    }

    void OnScriptExit(int code)
    {
        running = false;
        if (code == 2)
        {
            // uninstall.ps1 用 exit 2 表示"电源设置没能恢复", 这是唯一必须让用户知道的失败
            btnCancel.Enabled = true;
            btnCancel.Text = "关闭";
            SetHead("卸载未完成", "电源设置没能恢复");
            MessageBox.Show("程序文件已删除，但超低功耗模式的电源设置没能恢复。\r\n\r\n" +
                            "请重新安装一次再卸载，或手动把电源方案里的\r\n" +
                            "「最大处理器状态」改回 100%。", Setup.AppName,
                MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (code != 0)
        {
            btnCancel.Enabled = true;
            btnCancel.Text = "关闭";
            SetHead("卸载失败", "错误码 " + code);
            return;
        }
        if (Setup.quiet) { Setup.RemoveDirLater(AppDomain.CurrentDomain.BaseDirectory); Close(); return; }
        Go(2);
    }

    protected override void Finish()
    {
        // 此刻 Uninstall.exe 自己也还在这个目录里, 所以要等窗口关了再删
        Setup.RemoveDirLater(AppDomain.CurrentDomain.BaseDirectory);
        Close();
    }

    protected override void Cancel()
    {
        if (running) return;
        Close();
    }
}
