using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Threading;
using GamePulse.Windows.Infrastructure;
using GamePulse.Windows.Models;
using GamePulse.Windows.Services;

namespace GamePulse.Windows.ViewModels;

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly DispatcherTimer _clock;
    private readonly DispatcherTimer _refreshTimer;
    private bool _isBusy;
    private string _statusText = "准备就绪";

    public MainViewModel(SettingsStore settings)
    {
        Settings = settings;
        _clock = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _clock.Tick += (_, _) => { foreach (var game in Games) game.Apply(DateTimeOffset.Now); };
        _clock.Start();
        _refreshTimer = new DispatcherTimer();
        _refreshTimer.Tick += async (_, _) => await RefreshAsync();
        RestartTimer();
    }

    public SettingsStore Settings { get; }
    public ObservableCollection<GameCardViewModel> Games { get; } = [];
    public string SourceLabel => string.IsNullOrWhiteSpace(Settings.BridgeUrl)
        ? (Settings.HasAnyLiveAccount ? "官方社区实时数据" : "演示模式") : "数据桥实时数据";
    public string StatusText { get => _statusText; private set => Set(ref _statusText, value); }
    public Visibility BusyVisibility => _isBusy ? Visibility.Visible : Visibility.Collapsed;

    public async Task RefreshAsync()
    {
        if (_isBusy) return;
        _isBusy = true;
        OnPropertyChanged(nameof(BusyVisibility));
        StatusText = "正在刷新…";
        try
        {
            var statuses = string.IsNullOrWhiteSpace(Settings.BridgeUrl)
                ? await FetchDirectAsync()
                : await new BridgeStatusService(Settings.BridgeUrl, Settings.BridgeToken).FetchAsync();
            Games.Clear();
            foreach (var status in statuses.OrderBy(x => x.Id)) Games.Add(new GameCardViewModel(status));
            StatusText = $"已于 {DateTime.Now:HH:mm:ss} 更新";
            DiagnosticLog.Write($"refresh completed: {Games.Count} games");
        }
        catch (Exception error)
        {
            StatusText = error.Message;
            DiagnosticLog.Write($"refresh failed: {error}");
        }
        finally
        {
            _isBusy = false;
            OnPropertyChanged(nameof(BusyVisibility));
            OnPropertyChanged(nameof(SourceLabel));
        }
    }

    private async Task<IReadOnlyList<GameStatus>> FetchDirectAsync()
    {
        var demo = await new DemoStatusService().FetchAsync();
        if (!Settings.HasAnyLiveAccount) return demo;

        var merged = demo.ToDictionary(x => x.Id);
        var services = new List<(IStatusService Service, GameId[] Games)>();
        var mihoyo = new MihoyoClient(Settings);
        if (!string.IsNullOrWhiteSpace(Settings.MihoyoPrimaryCookie))
            services.Add((new MihoyoStatusService(mihoyo, Settings.MihoyoPrimaryCookie,
                new HashSet<GameId> { GameId.Genshin, GameId.StarRail }), [GameId.Genshin, GameId.StarRail]));
        if (!string.IsNullOrWhiteSpace(Settings.MihoyoZenlessCookie))
            services.Add((new MihoyoStatusService(mihoyo, Settings.MihoyoZenlessCookie,
                new HashSet<GameId> { GameId.Zenless }), [GameId.Zenless]));
        if (!string.IsNullOrWhiteSpace(Settings.SklandToken)) services.Add((new SklandStatusService(Settings.SklandToken), [GameId.Arknights]));
        if (!string.IsNullOrWhiteSpace(Settings.KuroToken)) services.Add((new KuroClient(Settings), [GameId.WutheringWaves]));

        foreach (var entry in services)
        {
            try
            {
                foreach (var status in await entry.Service.FetchAsync()) merged[status.Id] = status;
            }
            catch (Exception error)
            {
                DiagnosticLog.Write($"live service failed: {entry.Service.GetType().Name}: {error.Message}");
                foreach (var id in entry.Games)
                    merged[id] = new GameStatus(id, "体力", null, "每日进度", new DailyProgress(0, 0), [],
                        SessionState.Unavailable, error.Message, DateTimeOffset.Now);
            }
        }
        return merged.Values.ToList();
    }

    public void RestartTimer()
    {
        _refreshTimer.Stop();
        _refreshTimer.Interval = TimeSpan.FromMinutes(Math.Max(1, Settings.RefreshMinutes));
        _refreshTimer.Start();
        OnPropertyChanged(nameof(SourceLabel));
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    private void OnPropertyChanged([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new(name));
    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        OnPropertyChanged(name);
    }
}
