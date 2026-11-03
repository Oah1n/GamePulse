using System.Drawing;
using System.Windows.Forms;
using GamePulse.Windows.ViewModels;

namespace GamePulse.Windows.Infrastructure;

public sealed class TrayController : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly MainWindow _window;

    public TrayController(MainWindow window, MainViewModel viewModel)
    {
        _window = window;
        var menu = new ContextMenuStrip();
        menu.Items.Add("打开游戏脉冲", null, (_, _) => ToggleWindow(true));
        menu.Items.Add("立即刷新", null, async (_, _) => await viewModel.RefreshAsync());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => _window.ExitApplication());
        _icon = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Text = "GamePulse 游戏脉冲",
            Visible = true,
            ContextMenuStrip = menu
        };
        _icon.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleWindow(); };
    }

    private void ToggleWindow(bool forceShow = false)
    {
        if (_window.IsVisible && !forceShow) { _window.Hide(); return; }
        _window.Show();
        if (_window.WindowState == System.Windows.WindowState.Minimized)
            _window.WindowState = System.Windows.WindowState.Normal;
        _window.Activate();
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
    }
}
