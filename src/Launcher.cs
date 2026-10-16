using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("NUIST Electricity Query")]
[assembly: AssemblyDescription("Unofficial NUIST electricity query desktop widget")]
[assembly: AssemblyCompany("NUIST Electricity Query contributors")]
[assembly: AssemblyProduct("NUIST Electricity Query")]
[assembly: AssemblyVersion("0.1.0.0")]
[assembly: AssemblyFileVersion("0.1.0.0")]

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        bool demo = args.Length == 1 && args[0].Equals("--demo", StringComparison.OrdinalIgnoreCase);
        bool created;
        using (Mutex mutex = new Mutex(true, @"Local\NuistElectricityQuery_Launcher" + (demo ? "_Demo" : ""), out created))
        {
            if (!created) return;
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string script = Path.Combine(root, @"src\PowerBalance.ps1");
            string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "NuistElectricityQuery");
            string exitFlag = Path.Combine(data, "intentional-exit.flag");
            if (!File.Exists(script))
            {
                MessageBox.Show("Please fully extract the ZIP and keep src next to the EXE.", "NUIST Electricity Query");
                return;
            }
            try
            {
                if (!demo)
                {
                    Directory.CreateDirectory(data);
                    if (File.Exists(exitFlag)) File.Delete(exitFlag);
                }
                int failures = 0;
                while (true)
                {
                    ProcessStartInfo start = new ProcessStartInfo();
                    start.FileName = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
                    start.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\"" + (demo ? " -Demo" : "");
                    start.WorkingDirectory = root;
                    start.UseShellExecute = false;
                    start.CreateNoWindow = true;
                    start.WindowStyle = ProcessWindowStyle.Hidden;
                    using (Process process = Process.Start(start))
                    {
                        process.WaitForExit();
                        if (demo || process.ExitCode == 0) break;
                    }
                    if (File.Exists(exitFlag)) { File.Delete(exitFlag); break; }
                    if (++failures >= 3)
                    {
                        MessageBox.Show("The widget could not start. Run the source script to diagnose; do not share private headers or logs.", "NUIST Electricity Query");
                        break;
                    }
                    Thread.Sleep(3000);
                }
            }
            catch
            {
                MessageBox.Show("Unable to launch. Check that Windows PowerShell 5.1 and all package files are available.", "NUIST Electricity Query");
            }
        }
    }
}
