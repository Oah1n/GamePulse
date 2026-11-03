using System.IO;

namespace GamePulse.Windows.Infrastructure;

public static class DiagnosticLog
{
    private static readonly object Gate = new();
    public static string DirectoryPath { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GamePulse");
    public static string FilePath { get; } = Path.Combine(DirectoryPath, "diagnostics.log");

    public static void Reset()
    {
        Directory.CreateDirectory(DirectoryPath);
        lock (Gate) File.WriteAllText(FilePath, $"[{DateTimeOffset.Now:O}] diagnostics started{Environment.NewLine}");
    }

    public static void Write(string message)
    {
        Directory.CreateDirectory(DirectoryPath);
        lock (Gate) File.AppendAllText(FilePath, $"[{DateTimeOffset.Now:O}] {message}{Environment.NewLine}");
    }
}
