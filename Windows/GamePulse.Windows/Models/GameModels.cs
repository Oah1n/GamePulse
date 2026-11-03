using System.Text.Json.Serialization;

namespace GamePulse.Windows.Models;

public enum GameId
{
    Genshin,
    StarRail,
    Zenless,
    Arknights,
    WutheringWaves
}

public enum SessionState
{
    Active,
    NeedsLogin,
    Unavailable
}

public sealed record StaminaSnapshot(
    int Current,
    int Maximum,
    DateTimeOffset CapturedAt,
    double RecoverySecondsPerUnit)
{
    public int ValueAt(DateTimeOffset now)
    {
        if (Current >= Maximum || RecoverySecondsPerUnit <= 0) return Current;
        var recovered = (int)Math.Max(0, (now - CapturedAt).TotalSeconds / RecoverySecondsPerUnit);
        return Math.Min(Maximum, Current + recovered);
    }

    public DateTimeOffset? FullAt(DateTimeOffset now)
    {
        var remaining = Maximum - ValueAt(now);
        return remaining <= 0 ? null : now.AddSeconds(remaining * RecoverySecondsPerUnit);
    }
}

public sealed record DailyProgress(int Completed, int Total)
{
    public bool IsComplete => Total > 0 && Completed >= Total;
    public double Fraction => Total <= 0 ? 0 : Math.Clamp((double)Completed / Total, 0, 1);
}

public sealed record ChecklistItem(string Id, string Title, bool IsComplete, string? Detail);

public sealed record GameStatus(
    GameId Id,
    string StaminaName,
    StaminaSnapshot? Stamina,
    string DailyName,
    DailyProgress Daily,
    IReadOnlyList<ChecklistItem> Checklist,
    SessionState Session,
    string? Message,
    DateTimeOffset UpdatedAt);

public sealed record StatusEnvelope(DateTimeOffset GeneratedAt, IReadOnlyList<GameStatus> Games);

public static class GameMetadata
{
    public static string Title(this GameId id) => id switch
    {
        GameId.Genshin => "原神",
        GameId.StarRail => "崩坏：星穹铁道",
        GameId.Zenless => "绝区零",
        GameId.Arknights => "明日方舟",
        GameId.WutheringWaves => "鸣潮",
        _ => id.ToString()
    };

    public static (string Start, string End, string Icon) Visuals(this GameId id) => id switch
    {
        GameId.Genshin => ("#48ADDF", "#3364A8", "✦"),
        GameId.StarRail => ("#806DDB", "#40367F", "◈"),
        GameId.Zenless => ("#EFB71F", "#895C14", "⚡"),
        GameId.Arknights => ("#29B8C2", "#1A647F", "✚"),
        GameId.WutheringWaves => ("#2EBA9C", "#155C67", "≋"),
        _ => ("#777777", "#333333", "●")
    };
}
