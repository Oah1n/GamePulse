using System.Windows;
using GamePulse.Windows.Infrastructure;
using GamePulse.Windows.ViewModels;

namespace GamePulse.Windows;

public partial class App : System.Windows.Application
{
    private TrayController? _tray;
    private MainWindow? _mainWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, args) =>
        {
            DiagnosticLog.Write($"Unhandled UI error: {args.Exception}");
            System.Windows.MessageBox.Show(args.Exception.Message, "GamePulse", MessageBoxButton.OK, MessageBoxImage.Error);
            args.Handled = true;
        };

        DiagnosticLog.Reset();
        var settings = new SettingsStore();
        var viewModel = new MainViewModel(settings);
        _mainWindow = new MainWindow(viewModel);
        _tray = new TrayController(_mainWindow, viewModel);
        _mainWindow.Show();
        _mainWindow.Activate();
        _ = viewModel.RefreshAsync();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }
}
