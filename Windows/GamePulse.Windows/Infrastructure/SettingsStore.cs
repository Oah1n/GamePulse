using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.IO;

namespace GamePulse.Windows.Infrastructure;

public sealed class SettingsStore
{
    private readonly string _path;
    private SettingsDocument _document;

    public SettingsStore()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GamePulse");
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, "settings.json");
        _document = Load();
    }

    public string BridgeUrl { get => _document.BridgeUrl; set { _document.BridgeUrl = value.Trim(); Save(); } }
    public int RefreshMinutes { get => _document.RefreshMinutes; set { _document.RefreshMinutes = Math.Clamp(value, 1, 120); Save(); } }
    public string MihoyoPrimaryCookie { get => Decrypt(_document.MihoyoPrimaryCookie); set { _document.MihoyoPrimaryCookie = Encrypt(value); Save(); } }
    public string MihoyoZenlessCookie { get => Decrypt(_document.MihoyoZenlessCookie); set { _document.MihoyoZenlessCookie = Encrypt(value); Save(); } }
    public string SklandToken { get => Decrypt(_document.SklandToken); set { _document.SklandToken = Encrypt(value); Save(); } }
    public string KuroToken { get => Decrypt(_document.KuroToken); set { _document.KuroToken = Encrypt(value); Save(); } }
    public string BridgeToken { get => Decrypt(_document.BridgeToken); set { _document.BridgeToken = Encrypt(value); Save(); } }
    public string MihoyoDeviceId
    {
        get
        {
            if (string.IsNullOrWhiteSpace(_document.MihoyoDeviceId)) { _document.MihoyoDeviceId = Guid.NewGuid().ToString().ToLowerInvariant(); Save(); }
            return _document.MihoyoDeviceId;
        }
    }
    public string MihoyoDeviceFp
    {
        get
        {
            if (string.IsNullOrWhiteSpace(_document.MihoyoDeviceFp)) { _document.MihoyoDeviceFp = RandomHex13(); Save(); }
            return _document.MihoyoDeviceFp;
        }
        set { _document.MihoyoDeviceFp = value; Save(); }
    }
    public bool MihoyoDeviceFpRegistered { get => _document.MihoyoDeviceFpRegistered; set { _document.MihoyoDeviceFpRegistered = value; Save(); } }
    public string KuroDeviceCode
    {
        get
        {
            if (string.IsNullOrWhiteSpace(_document.KuroDeviceCode)) { _document.KuroDeviceCode = RandomKuroDeviceCode(); Save(); }
            return _document.KuroDeviceCode;
        }
    }
    public string KuroDistinctId
    {
        get
        {
            if (string.IsNullOrWhiteSpace(_document.KuroDistinctId)) { _document.KuroDistinctId = Guid.NewGuid().ToString().ToLowerInvariant(); Save(); }
            return _document.KuroDistinctId;
        }
    }

    public bool HasAnyLiveAccount => !string.IsNullOrWhiteSpace(MihoyoPrimaryCookie)
        || !string.IsNullOrWhiteSpace(MihoyoZenlessCookie)
        || !string.IsNullOrWhiteSpace(SklandToken)
        || !string.IsNullOrWhiteSpace(KuroToken);

    private SettingsDocument Load()
    {
        try
        {
            if (File.Exists(_path))
                return JsonSerializer.Deserialize<SettingsDocument>(File.ReadAllText(_path), JsonOptions) ?? new();
        }
        catch (Exception error) { DiagnosticLog.Write($"settings load failed: {error.Message}"); }
        return new();
    }

    private void Save()
    {
        var temporary = _path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(_document, JsonOptions));
        File.Move(temporary, _path, true);
    }

    private static string Encrypt(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "";
        var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(value.Trim()), null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(bytes);
    }

    private static string Decrypt(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return "";
        try
        {
            var bytes = ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch { return ""; }
    }

    private static string RandomHex13()
    {
        const string alphabet = "0123456789abcdef";
        return string.Concat(Enumerable.Range(0, 13).Select(_ => alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)]));
    }

    private static string RandomKuroDeviceCode()
    {
        var digest = SHA256.HashData(Encoding.UTF8.GetBytes(Guid.NewGuid().ToString()));
        return Convert.ToHexString(digest)[..40];
    }

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    private sealed class SettingsDocument
    {
        public string BridgeUrl { get; set; } = "";
        public int RefreshMinutes { get; set; } = 10;
        public string BridgeToken { get; set; } = "";
        public string MihoyoPrimaryCookie { get; set; } = "";
        public string MihoyoZenlessCookie { get; set; } = "";
        public string SklandToken { get; set; } = "";
        public string KuroToken { get; set; } = "";
        public string MihoyoDeviceId { get; set; } = "";
        public string MihoyoDeviceFp { get; set; } = "";
        public bool MihoyoDeviceFpRegistered { get; set; }
        public string KuroDeviceCode { get; set; } = "";
        public string KuroDistinctId { get; set; } = "";
    }
}
