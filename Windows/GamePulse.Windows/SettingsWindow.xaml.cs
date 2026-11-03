using System.Windows;
using GamePulse.Windows.Infrastructure;
using GamePulse.Windows.Services;
using GamePulse.Windows.ViewModels;

namespace GamePulse.Windows;

public partial class SettingsWindow : Window
{
    private readonly MainViewModel _viewModel;
    private SettingsStore Settings => _viewModel.Settings;

    public SettingsWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        RefreshBox.Text = Settings.RefreshMinutes.ToString();
        BridgeUrlBox.Text = Settings.BridgeUrl;
        BridgeTokenBox.Password = Settings.BridgeToken;
        UpdateStatuses();
    }

    private async void PrimaryLogin_Click(object sender, RoutedEventArgs e) => await LoginQrAsync(QrLoginWindow.LoginKind.MihoyoPrimary);
    private async void ZenlessLogin_Click(object sender, RoutedEventArgs e) => await LoginQrAsync(QrLoginWindow.LoginKind.MihoyoZenless);
    private async void SklandLogin_Click(object sender, RoutedEventArgs e) => await LoginQrAsync(QrLoginWindow.LoginKind.Skland);

    private async Task LoginQrAsync(QrLoginWindow.LoginKind kind)
    {
        var window = new QrLoginWindow(Settings, kind) { Owner = this };
        if (window.ShowDialog() == true) { UpdateStatuses(); await _viewModel.RefreshAsync(); }
    }

    private void PrimaryLogout_Click(object sender, RoutedEventArgs e) { Settings.MihoyoPrimaryCookie = ""; UpdateStatuses(); }
    private void ZenlessLogout_Click(object sender, RoutedEventArgs e) { Settings.MihoyoZenlessCookie = ""; UpdateStatuses(); }
    private void SklandLogout_Click(object sender, RoutedEventArgs e) { Settings.SklandToken = ""; UpdateStatuses(); }
    private void KuroLogout_Click(object sender, RoutedEventArgs e) { Settings.KuroToken = ""; KuroMessage.Text = ""; UpdateStatuses(); }

    private async void SendSms_Click(object sender, RoutedEventArgs e)
    {
        KuroMessage.Text = "正在发送…";
        try { await new KuroClient(Settings).SendSmsAsync(PhoneBox.Text.Trim()); KuroMessage.Text = "验证码已发送，请查看手机短信"; }
        catch (Exception error) { KuroMessage.Text = error.Message; }
    }

    private async void KuroLogin_Click(object sender, RoutedEventArgs e)
    {
        KuroMessage.Text = "正在登录…";
        try
        {
            Settings.KuroToken = await new KuroClient(Settings).LoginAsync(PhoneBox.Text.Trim(), SmsBox.Text.Trim());
            PhoneBox.Clear(); SmsBox.Clear(); KuroMessage.Text = "登录成功"; UpdateStatuses();
            await _viewModel.RefreshAsync();
        }
        catch (Exception error) { KuroMessage.Text = error.Message; }
    }

    private async void Save_Click(object sender, RoutedEventArgs e)
    {
        Settings.BridgeUrl = BridgeUrlBox.Text;
        Settings.BridgeToken = BridgeTokenBox.Password;
        Settings.RefreshMinutes = int.TryParse(RefreshBox.Text, out var minutes) ? minutes : 10;
        _viewModel.RestartTimer();
        await _viewModel.RefreshAsync();
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => Close();

    private void UpdateStatuses()
    {
        Apply(PrimaryStatus, !string.IsNullOrWhiteSpace(Settings.MihoyoPrimaryCookie));
        Apply(ZenlessStatus, !string.IsNullOrWhiteSpace(Settings.MihoyoZenlessCookie));
        Apply(SklandStatus, !string.IsNullOrWhiteSpace(Settings.SklandToken));
        Apply(KuroStatus, !string.IsNullOrWhiteSpace(Settings.KuroToken));
    }

    private static void Apply(System.Windows.Controls.TextBlock label, bool loggedIn)
    {
        label.Text = loggedIn ? "● 已登录" : "○ 未登录";
        label.Foreground = new System.Windows.Media.SolidColorBrush(
            (System.Windows.Media.Color)System.Windows.Media.ColorConverter.ConvertFromString(loggedIn ? "#27B963" : "#8A8E99"));
    }
}
