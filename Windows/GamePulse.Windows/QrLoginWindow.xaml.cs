using System.IO;
using System.Windows;
using System.Windows.Media.Imaging;
using GamePulse.Windows.Infrastructure;
using GamePulse.Windows.Services;
using QRCoder;

namespace GamePulse.Windows;

public partial class QrLoginWindow : Window
{
    private readonly CancellationTokenSource _cancel = new();
    private readonly SettingsStore _settings;
    private readonly LoginKind _kind;

    public enum LoginKind { MihoyoPrimary, MihoyoZenless, Skland }

    public QrLoginWindow(SettingsStore settings, LoginKind kind)
    {
        InitializeComponent();
        _settings = settings;
        _kind = kind;
        TitleText.Text = kind switch
        {
            LoginKind.MihoyoPrimary => "米游社主账号",
            LoginKind.MihoyoZenless => "米游社绝区零账号",
            _ => "森空岛账号"
        };
        InstructionText.Text = kind == LoginKind.Skland
            ? "请使用森空岛 App 扫描二维码并在手机上确认"
            : "请使用米游社 App 扫描二维码并在手机上确认。米游社需要连续完成两次官方授权。";
        Loaded += async (_, _) => await RunAsync();
        Closed += (_, _) => _cancel.Cancel();
    }

    private async Task RunAsync()
    {
        try
        {
            if (_kind == LoginKind.Skland) await RunSklandAsync(); else await RunMihoyoAsync();
            StatusText.Text = "登录成功";
            DialogResult = true;
        }
        catch (OperationCanceledException) { }
        catch (Exception error)
        {
            StatusText.Text = error.Message;
            DiagnosticLog.Write($"QR login failed: {_kind}: {error}");
        }
    }

    private async Task RunSklandAsync()
    {
        var client = new SklandLoginClient();
        var session = await client.CreateAsync(_cancel.Token);
        ShowQr(session.Url);
        StatusText.Text = "等待扫码…";
        while (!_cancel.IsCancellationRequested)
        {
            var token = await client.PollAsync(session, _cancel.Token);
            if (!string.IsNullOrWhiteSpace(token)) { _settings.SklandToken = token; return; }
            await Task.Delay(1800, _cancel.Token);
        }
    }

    private async Task RunMihoyoAsync()
    {
        var client = new MihoyoClient(_settings);
        var app = await client.CreateAppQrAsync(_cancel.Token);
        ShowQr(app.Url);
        StatusText.Text = "第一次授权：等待米游社扫码…";
        MihoyoCredentials? credentials = null;
        while (credentials is null)
        {
            var poll = await client.PollAppQrAsync(app, _cancel.Token);
            StatusText.Text = poll.State == QrPollState.Scanned ? "已扫码，请在手机上确认" : "第一次授权：等待扫码…";
            credentials = poll.Credentials;
            if (credentials is null) await Task.Delay(1500, _cancel.Token);
        }

        var web = await client.CreateWebQrAsync(app.DeviceId, _cancel.Token);
        ShowQr(web.Url);
        StatusText.Text = "第二次授权：请再次扫码确认";
        string? webCookie = null;
        while (string.IsNullOrWhiteSpace(webCookie))
        {
            var poll = await client.PollWebQrAsync(web, _cancel.Token);
            StatusText.Text = poll.State == QrPollState.Scanned ? "已扫码，请在手机上确认" : "第二次授权：等待扫码…";
            webCookie = poll.Cookie;
            if (string.IsNullOrWhiteSpace(webCookie)) await Task.Delay(1500, _cancel.Token);
        }
        var cookie = client.CombineCookie(credentials, webCookie);
        if (_kind == LoginKind.MihoyoZenless) _settings.MihoyoZenlessCookie = cookie;
        else _settings.MihoyoPrimaryCookie = cookie;
    }

    private void ShowQr(string content)
    {
        using var data = QRCodeGenerator.GenerateQrCode(content, QRCodeGenerator.ECCLevel.M);
        using var qr = new PngByteQRCode(data);
        var bytes = qr.GetGraphic(8);
        using var stream = new MemoryStream(bytes);
        var image = new BitmapImage();
        image.BeginInit(); image.CacheOption = BitmapCacheOption.OnLoad; image.StreamSource = stream; image.EndInit(); image.Freeze();
        QrImage.Source = image;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) { _cancel.Cancel(); Close(); }
}
