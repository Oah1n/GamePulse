using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using GamePulse.Windows.Infrastructure;
using GamePulse.Windows.Models;

namespace GamePulse.Windows.Services;

public sealed record SklandQrSession(string ScanId, string Url);

public sealed class SklandLoginClient
{
    private const string AppCode = "4ca99fa6b56cc2ba";
    private readonly HttpClient _client = ApiHttp.CreateClient();

    public async Task<SklandQrSession> CreateAsync(CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://as.hypergryph.com/general/v1/gen_scan/login")
        {
            Content = ApiHttp.JsonContent(new { appCode = AppCode })
        };
        AddDeviceHeaders(request);
        var json = await ApiHttp.SendAsync(_client, request, cancellationToken);
        if (json.Int("status") != 0) throw new InvalidOperationException(json.Text("msg") ?? "无法生成森空岛登录二维码");
        var data = json["data"]?.AsObject() ?? throw new InvalidOperationException("森空岛返回了无法识别的数据");
        return new(data.Text("scanId") ?? throw new InvalidOperationException("缺少 scanId"),
            data.Text("scanUrl") ?? throw new InvalidOperationException("缺少二维码地址"));
    }

    public async Task<string?> PollAsync(SklandQrSession session, CancellationToken cancellationToken = default)
    {
        var uri = $"https://as.hypergryph.com/general/v1/scan_status?scanId={Uri.EscapeDataString(session.ScanId)}";
        var json = await ApiHttp.GetAsync(_client, uri, cancellationToken);
        if (json.Int("status") == 0 && json["data"]?.AsObject().Text("scanCode") is { Length: > 0 } scanCode)
            return await ExchangeTokenAsync(scanCode, cancellationToken);
        var message = json.Text("msg") ?? "";
        if (message.Contains("过期") || message.Contains("expire", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("森空岛二维码已过期，请重新生成");
        return null;
    }

    private async Task<string> ExchangeTokenAsync(string scanCode, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://as.hypergryph.com/user/auth/v1/token_by_scan_code")
        {
            Content = ApiHttp.JsonContent(new { scanCode, appCode = AppCode })
        };
        AddDeviceHeaders(request);
        var json = await ApiHttp.SendAsync(_client, request, cancellationToken);
        var token = json["data"]?.AsObject().Text("token");
        if (json.Int("status") != 0 || string.IsNullOrWhiteSpace(token))
            throw new InvalidOperationException(json.Text("msg") ?? "森空岛扫码登录失败");
        return token;
    }

    private static void AddDeviceHeaders(HttpRequestMessage request)
    {
        request.Headers.TryAddWithoutValidation("X-DeviceId", Guid.NewGuid().ToString("N"));
        request.Headers.TryAddWithoutValidation("X-DeviceModel", "Chrome");
        request.Headers.TryAddWithoutValidation("X-DeviceType", "7");
        request.Headers.TryAddWithoutValidation("X-OSVer", "Windows 11");
    }
}

public sealed class SklandStatusService(string accountToken) : IStatusService
{
    private const string UserAgent = "Skland/1.5.1 (com.hypergryph.skland; build:100501001; Android 34; ) Okhttp/4.11.0";
    private const string AppCode = "4ca99fa6b56cc2ba";
    private readonly HttpClient _client = ApiHttp.CreateClient();

    public async Task<IReadOnlyList<GameStatus>> FetchAsync(CancellationToken cancellationToken = default)
    {
        var token = ExtractToken(accountToken);
        var grant = await PostAsync("https://as.hypergryph.com/user/oauth2/v2/grant", new { appCode = AppCode, token, type = 0 }, "status", cancellationToken);
        var code = grant["data"]?.AsObject().Text("code") ?? throw new InvalidOperationException("森空岛授权失败");
        var credential = await PostAsync("https://zonai.skland.com/web/v1/user/auth/generate_cred_by_code", new { code, kind = 1 }, "code", cancellationToken);
        var credentialData = credential["data"]?.AsObject() ?? throw new InvalidOperationException("森空岛凭据无效");
        var cred = credentialData.Text("cred") ?? throw new InvalidOperationException("森空岛凭据无效");
        var signToken = credentialData.Text("token") ?? throw new InvalidOperationException("森空岛签名凭据无效");

        var binding = await SignedGetAsync(new Uri("https://zonai.skland.com/api/v1/game/player/binding"), cred, signToken, cancellationToken);
        var apps = binding["data"]?["list"]?.AsArray() ?? throw new InvalidOperationException("森空岛未返回游戏绑定");
        var arknights = apps.Select(x => x?.AsObject()).FirstOrDefault(x => x?.Text("appCode") == "arknights");
        var roles = arknights?["bindingList"]?.AsArray() ?? throw new InvalidOperationException("森空岛中未找到明日方舟角色");
        var role = roles.Select(x => x?.AsObject()).FirstOrDefault(x => x?.Text("channelName")?.Contains("官服") == true || x?.Text("channelMasterId") == "1")
            ?? roles.FirstOrDefault()?.AsObject() ?? throw new InvalidOperationException("森空岛中未找到明日方舟官服角色");
        var uid = role.Text("uid") ?? throw new InvalidOperationException("明日方舟 UID 缺失");
        var info = await SignedGetAsync(new Uri($"https://zonai.skland.com/api/v1/game/player/info?uid={Uri.EscapeDataString(uid)}"), cred, signToken, cancellationToken);
        var data = info["data"]?.AsObject() ?? throw new InvalidOperationException("森空岛数据不完整");
        var status = data["status"]?.AsObject() ?? throw new InvalidOperationException("森空岛状态缺失");
        var ap = status["ap"]?.AsObject() ?? throw new InvalidOperationException("理智数据缺失");
        var daily = data["routine"]?["daily"]?.AsObject() ?? throw new InvalidOperationException("日常任务数据缺失");
        var serverTime = data.Int("currentTs");
        var maximum = ap.Int("max");
        var baseAp = ap.Int("current");
        var fullTime = ap.Int("completeRecoveryTime");
        var current = baseAp;
        if (serverTime > 0 && fullTime > serverTime && maximum > 0)
            current = Math.Max(0, maximum - ((fullTime - serverTime + 359) / 360));
        else if (serverTime > 0 && fullTime > 0 && fullTime <= serverTime) current = maximum;
        var now = DateTimeOffset.Now;
        var captured = serverTime > 1_500_000_000 ? DateTimeOffset.FromUnixTimeSeconds(serverTime) : now;
        var nickname = role.Text("nickName") ?? status.Text("name") ?? "博士";
        return [new GameStatus(GameId.Arknights, "理智", new(current, maximum, captured, 360), "日常任务",
            new(daily.Int("current"), daily.Int("total")), [], SessionState.Active, $"{nickname} · UID {uid[^Math.Min(4, uid.Length)..]}", now)];
    }

    private async Task<JsonObject> PostAsync(string url, object body, string codeKey, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url) { Content = ApiHttp.JsonContent(body) };
        request.Headers.UserAgent.ParseAdd(UserAgent);
        var json = await ApiHttp.SendAsync(_client, request, ct);
        if (json.Int(codeKey) != 0) throw new InvalidOperationException("森空岛：" + (json.Text("message") ?? json.Text("msg") ?? "授权失败"));
        return json;
    }

    private async Task<JsonObject> SignedGetAsync(Uri uri, string cred, string signToken, CancellationToken ct)
    {
        var timestamp = DateTimeOffset.UtcNow.ToUnixTimeSeconds() - 2;
        var device = Convert.ToBase64String(RandomNumberGenerator.GetBytes(16)).TrimEnd('=').Replace('+', '-').Replace('/', '_');
        var fields = $"{{\"platform\":\"1\",\"timestamp\":\"{timestamp}\",\"dId\":\"{device}\",\"vName\":\"1.5.1\"}}";
        var source = uri.AbsolutePath + uri.Query.TrimStart('?') + timestamp + fields;
        var hmac = HMACSHA256.HashData(Encoding.UTF8.GetBytes(signToken), Encoding.UTF8.GetBytes(source));
        var hmacHex = Convert.ToHexString(hmac).ToLowerInvariant();
        var signature = Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(hmacHex))).ToLowerInvariant();
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.UserAgent.ParseAdd(UserAgent);
        request.Headers.TryAddWithoutValidation("cred", cred);
        request.Headers.TryAddWithoutValidation("sign", signature);
        request.Headers.TryAddWithoutValidation("timestamp", timestamp.ToString());
        request.Headers.TryAddWithoutValidation("platform", "1");
        request.Headers.TryAddWithoutValidation("dId", device);
        request.Headers.TryAddWithoutValidation("vName", "1.5.1");
        var json = await ApiHttp.SendAsync(_client, request, ct);
        if (json.Int("code") != 0) throw new InvalidOperationException("森空岛：" + (json.Text("message") ?? "请求失败"));
        return json;
    }

    private static string ExtractToken(string value)
    {
        var trimmed = value.Trim();
        try
        {
            var json = JsonNode.Parse(trimmed)?.AsObject();
            return json?["data"]?["content"]?.GetValue<string>() ?? json?["content"]?.GetValue<string>() ?? trimmed;
        }
        catch { return trimmed; }
    }
}

public sealed class KuroClient(SettingsStore settings) : IStatusService
{
    private readonly HttpClient _client = ApiHttp.CreateClient();

    public async Task SendSmsAsync(string phone, CancellationToken ct = default)
    {
        var json = await PostAsync("/user/getSmsCode", new() { ["mobile"] = phone, ["geeTestData"] = "" }, null, ct);
        if (json.Int("code") != 200) throw new InvalidOperationException("库街区：" + (json.Text("msg") ?? "发送验证码失败"));
        if (json["data"]?.AsObject().Bool("geeTest") == true)
            throw new InvalidOperationException("库街区要求人机验证。请先在库街区 App 或官方网页获取验证码。");
    }

    public async Task<string> LoginAsync(string phone, string code, CancellationToken ct = default)
    {
        var json = await PostAsync("/user/sdkLogin", new()
        {
            ["code"] = code, ["devCode"] = settings.KuroDeviceCode, ["gameList"] = "", ["mobile"] = phone
        }, null, ct);
        var token = json["data"]?.AsObject().Text("token");
        if (json.Int("code") != 200 || string.IsNullOrWhiteSpace(token))
            throw new InvalidOperationException("库街区：" + (json.Text("msg") ?? "登录失败"));
        return token;
    }

    public async Task<IReadOnlyList<GameStatus>> FetchAsync(CancellationToken cancellationToken = default)
    {
        var token = settings.KuroToken.Trim();
        if (token.Contains("token=")) token = token.Split("token=", 2)[1].Split(';', ' ')[0];
        if (string.IsNullOrWhiteSpace(token)) throw new InvalidOperationException("库街区未登录");
        var roles = await PostAsync("/gamer/role/list", new() { ["gameId"] = "3" }, token, cancellationToken);
        var roleArray = roles["data"]?.AsArray() ?? throw new InvalidOperationException("库街区中未找到鸣潮角色");
        var role = roleArray.Select(x => x?.AsObject()).FirstOrDefault(x => x?.Bool("isDefault") == true)
            ?? roleArray.FirstOrDefault()?.AsObject() ?? throw new InvalidOperationException("库街区中未找到鸣潮官服角色");
        var roleId = role.Text("roleId") ?? throw new InvalidOperationException("鸣潮 UID 缺失");
        var serverId = role.Text("serverId") ?? throw new InvalidOperationException("鸣潮服务器缺失");
        var widget = await PostAsync("/gamer/widget/game3/refresh", new()
        {
            ["gameId"] = "3", ["roleId"] = roleId, ["serverId"] = serverId, ["type"] = "2", ["sizeType"] = "1"
        }, token, cancellationToken);
        var data = widget["data"]?.AsObject() ?? throw new InvalidOperationException("库街区数据不完整");
        var energy = data["energyData"]?.AsObject() ?? throw new InvalidOperationException("结晶波片数据缺失");
        var liveness = data["livenessData"]?.AsObject() ?? throw new InvalidOperationException("每日活跃数据缺失");
        var now = DateTimeOffset.Now;
        var serverTime = data.Int("serverTime");
        var captured = serverTime > 1_500_000_000 ? DateTimeOffset.FromUnixTimeSeconds(serverTime) : now;
        var nickname = role.Text("roleName") ?? data.Text("roleName") ?? "漂泊者";
        var signed = data.Bool("hasSignIn");
        return [new GameStatus(GameId.WutheringWaves, energy.Text("name") ?? "结晶波片",
            new(energy.Int("cur"), energy.Int("total"), captured, 360), liveness.Text("name") ?? "每日活跃",
            new(liveness.Int("cur"), liveness.Int("total")), [new("kuro-sign-in", "库街区签到", signed, signed ? "已完成" : "待完成")],
            SessionState.Active, $"{nickname} · UID {roleId[^Math.Min(4, roleId.Length)..]}", now)];
    }

    private async Task<JsonObject> PostAsync(string path, Dictionary<string, string> fields, string? token, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://api.kurobbs.com" + path)
        {
            Content = new FormUrlEncodedContent(fields.OrderBy(x => x.Key))
        };
        foreach (var (key, value) in Headers(token)) request.Headers.TryAddWithoutValidation(key, value);
        return await ApiHttp.SendAsync(_client, request, ct);
    }

    private Dictionary<string, string> Headers(string? token)
    {
        var headers = new Dictionary<string, string>
        {
            ["osVersion"] = "Android", ["devCode"] = settings.KuroDeviceCode, ["distinct_id"] = settings.KuroDistinctId,
            ["ip"] = "192.168.1.114", ["countryCode"] = "CN", ["model"] = "23127PN0CC", ["source"] = "android",
            ["lang"] = "zh-Hans", ["version"] = "2.2.1", ["versionCode"] = "2210", ["channelId"] = "2",
            ["User-Agent"] = "okhttp/3.11.0"
        };
        if (!string.IsNullOrWhiteSpace(token)) headers["token"] = token;
        return headers;
    }
}

internal static class ApiHttp
{
    public static HttpClient CreateClient() => new(new HttpClientHandler { AutomaticDecompression = DecompressionMethods.All })
    {
        Timeout = TimeSpan.FromSeconds(20)
    };

    public static StringContent JsonContent(object value) => new(JsonSerializer.Serialize(value), Encoding.UTF8, "application/json");

    public static async Task<JsonObject> GetAsync(HttpClient client, string url, CancellationToken ct) =>
        await SendAsync(client, new HttpRequestMessage(HttpMethod.Get, url), ct);

    public static async Task<JsonObject> SendAsync(HttpClient client, HttpRequestMessage request, CancellationToken ct)
    {
        using var response = await client.SendAsync(request, ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        JsonObject? json = null;
        try { json = JsonNode.Parse(body)?.AsObject(); } catch { }
        DiagnosticLog.Write($"community response {request.RequestUri?.Host}{request.RequestUri?.AbsolutePath}: http={(int)response.StatusCode}, bytes={body.Length}");
        if (!response.IsSuccessStatusCode || json is null)
            throw new InvalidOperationException(json?.Text("message") ?? json?.Text("msg") ?? $"请求失败（HTTP {(int)response.StatusCode}）");
        return json;
    }
}

internal static class JsonExtensions
{
    public static string? Text(this JsonObject value, string key)
    {
        var node = value[key];
        if (node is null) return null;
        try { return node.GetValue<string>(); } catch { return node.ToJsonString().Trim('"'); }
    }

    public static int Int(this JsonObject value, string key)
    {
        var node = value[key];
        if (node is null) return 0;
        try { return node.GetValue<int>(); } catch { return int.TryParse(value.Text(key), out var result) ? result : 0; }
    }

    public static bool Bool(this JsonObject value, string key)
    {
        var node = value[key];
        if (node is null) return false;
        try { return node.GetValue<bool>(); } catch { return value.Text(key) is "1" or "true" or "True"; }
    }
}
