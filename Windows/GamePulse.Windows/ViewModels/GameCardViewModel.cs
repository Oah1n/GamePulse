using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Media;
using GamePulse.Windows.Models;

namespace GamePulse.Windows.ViewModels;

public sealed class GameCardViewModel : INotifyPropertyChanged
{
    private readonly GameStatus _status;
    private int _current;
    private int _progressPercent;
    private string _fullTimeText = "";

    public GameCardViewModel(GameStatus status)
    {
        _status = status;
        var (start, end, icon) = status.Id.Visuals();
        GradientStart = (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(start);
        GradientEnd = (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(end);
        Icon = icon;
        Apply(DateTimeOffset.Now);
    }

    public string Title => _status.Id.Title();
    public string Icon { get; }
    public System.Windows.Media.Color GradientStart { get; }
    public System.Windows.Media.Color GradientEnd { get; }
    public string Message => _status.Message ?? $"更新于 {_status.UpdatedAt:HH:mm}";
    public string SessionText => _status.Session switch { SessionState.Active => "● 已同步", SessionState.NeedsLogin => "● 待登录", _ => "● 暂不可用" };
    public string StaminaName => _status.StaminaName;
    public int Maximum => _status.Stamina?.Maximum ?? 0;
    public int Current { get => _current; private set => Set(ref _current, value); }
    public int ProgressPercent { get => _progressPercent; private set => Set(ref _progressPercent, value); }
    public string FullTimeText { get => _fullTimeText; private set => Set(ref _fullTimeText, value); }
    public string DailyName => _status.DailyName;
    public string DailyText => _status.Daily.IsComplete ? $"{_status.Daily.Completed} / {_status.Daily.Total}  已完成" : $"{_status.Daily.Completed} / {_status.Daily.Total}";
    public double DailyPercent => _status.Daily.Fraction * 100;

    public void Apply(DateTimeOffset now)
    {
        var stamina = _status.Stamina;
        if (stamina is null) { Current = 0; ProgressPercent = 0; FullTimeText = ""; return; }
        Current = stamina.ValueAt(now);
        ProgressPercent = stamina.Maximum <= 0 ? 0 : (int)Math.Round((double)Current / stamina.Maximum * 100);
        FullTimeText = stamina.FullAt(now) is { } full ? $"{full:HH:mm} 回满" : "已回满";
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
    }
}
