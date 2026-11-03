using System.ComponentModel;
using System.Windows;
using GamePulse.Windows.ViewModels;

namespace GamePulse.Windows;

public partial class MainWindow : Window
{
    private readonly MainViewModel _viewModel;
    private bool _allowClose;

    public MainWindow(MainViewModel viewModel)
    {
        InitializeComponent();
        _viewModel = viewModel;
        DataContext = viewModel;
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await _viewModel.RefreshAsync();

    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        var window = new SettingsWindow(_viewModel) { Owner = this };
        window.ShowDialog();
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_allowClose)
        {
            e.Cancel = true;
            Hide();
            return;
        }
        base.OnClosing(e);
    }

    public void ExitApplication()
    {
        _allowClose = true;
        Close();
        System.Windows.Application.Current.Shutdown();
    }
}
