using System.Security.Cryptography;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using GamePulse.Windows.Infrastructure;
using GamePulse.Windows.Models;

namespace GamePulse.Windows.Services;

public sealed record MihoyoQrSession(string Ticket, string Url, string DeviceId);
public sealed record MihoyoCredentials(string Uid, string SToken, string Mid, string CookieToken);
public enum QrPollState { Waiting, Scanned, Confirmed }
public sealed record MihoyoAppPoll(QrPollState State, MihoyoCredentials? Credentials = null);
public sealed record MihoyoWebPoll(QrPollState State, string? Cookie = null);
public sealed record MihoyoRole(string GameBiz, string Region, string GameUid, string Nickname, bool IsOfficial);

public sealed class MihoyoClient(SettingsStore settings)
{
    private const string QrAppId = "bll8iq97cem8";
    private const string QrVersion = "2.90.1";
    private const string QrDeviceFp = "38d7fa104e5d7";
    private readonly HttpClient _client = ApiHttp.CreateClient();

    public async Task<MihoyoQrSession> CreateAppQrAsync(CancellationToken ct = default)
    {
        var device = RandomString(16, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789");
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://passport-api.mihoyo.com/account/ma-cn-passport/app/createQRLogin")
        {
            Content = ApiHttp.JsonContent(new { })
        };
        AddAppQrHeaders(request, device);
        var json = await SendMihoyoAsync(request, ct);
        var data = json["data"]?.AsObject() ?? throw new InvalidOperationException("米游社二维码数据缺失");
        return new(data.Text("ticket") ?? throw new InvalidOperationException("缺少 ticket"),
            data.Text("url") ?? throw new InvalidOperationException("缺少二维码地址"), device);
    }

    public async Task<MihoyoAppPoll> PollAppQrAsync(MihoyoQrSession session, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://passport-api.mihoyo.com/account/ma-cn-passport/app/queryQRLoginStatus")
        {
            Content = ApiHttp.JsonContent(new { ticket = session.Ticket })
        };
        AddAppQrHeaders(request, session.DeviceId);
        var json = await SendMihoyoAsync(request, ct);
        var data = json["data"]?.AsObject() ?? throw new InvalidOperationException("米游社登录状态缺失");
        return data.Text("status") switch
        {
            "Created" or "Init" => new(QrPollState.Waiting),
            "Scanned" => new(QrPollState.Scanned),
            "Confirmed" => new(QrPollState.Confirmed, await CredentialsAsync(data, ct)),
            var state => throw new InvalidOperationException($"未知的米游社授权状态：{state}")
        };
    }

    public async Task<MihoyoQrSession> CreateWebQrAsync(string device, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://passport-api.miyoushe.com/account/ma-cn-passport/web/createQRLogin");
        AddWebQrHeaders(request, device);
        var json = await SendMihoyoAsync(request, ct);
        var data = json["data"]?.AsObject() ?? throw new InvalidOperationException("米游社网页登录数据缺失");
        return new(data.Text("ticket") ?? throw new InvalidOperationException("缺少 ticket"),
            data.Text("url") ?? throw new InvalidOperationException("缺少二维码地址"), device);
    }

    public async Task<MihoyoWebPoll> PollWebQrAsync(MihoyoQrSession session, CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://passport-api.miyoushe.com/account/ma-cn-passport/web/queryQRLoginStatus")
        {
            Content = ApiHttp.JsonContent(new { ticket = session.Ticket })
        };
        AddWebQrHeaders(request, session.DeviceId);
        using var response = await _client.SendAsync(request, ct);
        var body = await response.Content.ReadAsStringAsync(ct);
        var json = JsonNode.Parse(body)?.AsObject() ?? throw new InvalidOperationException("米游社返回了无法识别的数据");
        EnsureMihoyoSuccess(json);
        var data = json["data"]?.AsObject() ?? throw new InvalidOperationException("米游社登录状态缺失");
        return data.Text("status") switch
        {
            "Created" => new(QrPollState.Waiting),
            "Scanned" => new(QrPollState.Scanned),
            "Confirmed" => new(QrPollState.Confirmed, Cookie: NormalizeCookie(CookiesFrom(response))),
            var state => throw new InvalidOperationException($"未知的米游社扫码状态：{state}")
        };
    }

    public string CombineCookie(MihoyoCredentials credentials, string webCookie)
    {
        var values = ParseCookie(NormalizeCookie(webCookie));
        var webUid = Value(values, "account_id_v2", "ltuid_v2", "account_id");
        var webMid = Value(values, "account_mid_v2", "ltmid_v2", "mid");
        if (webUid != credentials.Uid || webMid != credentials.Mid)
            throw new InvalidOperationException("两次扫码不是同一个米游社账号，请重新完整登录");
        values["stoken"] = credentials.SToken;
        values["stuid"] = credentials.Uid;
        values["mid"] = credentials.Mid;
        values["cookie_token"] = credentials.CookieToken;
        if (credentials.SToken.StartsWith("v2_")) values["stoken_v2"] = credentials.SToken;
        values["account_id"] = values["login_uid"] = values["ltuid"] = credentials.Uid;
        return FormatCookie(values);
    }

    public async Task<IReadOnlyList<MihoyoRole>> RolesAsync(string cookie, CancellationToken ct = default)
    {
        await EnsureDeviceFpAsync(ct);
        var json = await SignedGetAsync("https://api-takumi.mihoyo.com/binding/api/getUserGameRolesByCookie", [], cookie, ct);
        var list = json["list"]?.AsArray() ?? [];
        return list.Select(node => node?.AsObject()).OfType<JsonObject>().Select(x => new MihoyoRole(
            x.Text("game_biz") ?? "", x.Text("region") ?? "", x.Text("game_uid") ?? "",
            x.Text("nickname") ?? "旅行者", x["is_official"] is null || x.Bool("is_official"))).ToList();
    }

    public async Task<GameStatus> StatusAsync(MihoyoRole role, string cookie, CancellationToken ct = default)
    {
        var (id, url, staminaName, dailyName, recovery, widget) = role.GameBiz switch
        {
            "hk4e_cn" => (GameId.Genshin, "https://api-takumi-record.mihoyo.com/game_record/genshin/aapi/widget/v2", "原粹树脂", "每日委托", 480d, true),
            "hkrpg_cn" => (GameId.StarRail, "https://api-takumi-record.mihoyo.com/game_record/app/hkrpg/aapi/widget", "开拓力", "每日训练", 360d, true),
            "nap_cn" => (GameId.Zenless, "https://api-takumi-record.mihoyo.com/event/game_record_zzz/api/zzz/widget", "电量", "活跃度", 360d, false),
            _ => throw new InvalidOperationException("不支持的米游社游戏")
        };
        JsonObject data;
        if (widget) data = await WidgetGetAsync(url, id, cookie, ct);
        else data = await SignedGetAsync(url, new() { ["server"] = role.Region, ["role_id"] = role.GameUid }, cookie, ct);
        var (current, maximum, dailyCurrent, dailyMaximum, checklist) = Normalize(id, data);
        var now = DateTimeOffset.Now;
        return new(id, staminaName, new(current, maximum, now, recovery), dailyName, new(dailyCurrent, dailyMaximum), checklist,
            SessionState.Active, $"{role.Nickname} · UID {role.GameUid[^Math.Min(4, role.GameUid.Length)..]}", now);
    }

    private async Task<MihoyoCredentials> CredentialsAsync(JsonObject data, CancellationToken ct)
    {
        var user = data["user_info"]?.AsObject() ?? throw new InvalidOperationException("米游社未返回账号信息");
        var tokens = data["tokens"]?.AsArray() ?? throw new InvalidOperationException("米游社未返回授权凭据");
        var uid = user.Text("aid") ?? user.Text("uid") ?? user.Text("account_id") ?? "";
        var mid = user.Text("mid") ?? "";
        var tokenObject = tokens.Select(x => x?.AsObject()).FirstOrDefault(x => x?.Text("name") is "stoken" or "stoken_v2") ?? tokens.FirstOrDefault()?.AsObject();
        var stoken = tokenObject?.Text("token") ?? "";
        if (string.IsNullOrWhiteSpace(uid) || string.IsNullOrWhiteSpace(mid) || string.IsNullOrWhiteSpace(stoken))
            throw new InvalidOperationException("登录成功但未收到完整会话凭据");
        var cookieToken = await ExchangeCookieTokenAsync(uid, stoken, mid, ct);
        return new(uid, stoken, mid, cookieToken);
    }

    private async Task<string> ExchangeCookieTokenAsync(string uid, string stoken, string mid, CancellationToken ct)
    {
        var uri = $"https://passport-api.mihoyo.com/account/auth/api/getCookieAccountInfoBySToken?stoken={Uri.EscapeDataString(stoken)}&uid={Uri.EscapeDataString(uid)}&mid={Uri.EscapeDataString(mid)}";
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.TryAddWithoutValidation("Cookie", $"stoken={stoken}; stuid={uid}; mid={mid}");
        request.Headers.UserAgent.ParseAdd(QrUserAgent);
        var json = await SendMihoyoAsync(request, ct);
        return json["data"]?.AsObject().Text("cookie_token") ?? throw new InvalidOperationException("未收到 cookie_token");
    }

    private async Task<JsonObject> SignedGetAsync(string url, Dictionary<string, string> query, string cookie, CancellationToken ct)
    {
        var queryString = string.Join("&", query.OrderBy(x => x.Key).Select(x => $"{Uri.EscapeDataString(x.Key)}={Uri.EscapeDataString(x.Value)}"));
        var finalUrl = string.IsNullOrWhiteSpace(queryString) ? url : url + "?" + queryString;
        using var request = new HttpRequestMessage(HttpMethod.Get, finalUrl);
        request.Headers.TryAddWithoutValidation("Cookie", cookie);
        request.Headers.TryAddWithoutValidation("x-rpc-app_version", "2.11.1");
        request.Headers.TryAddWithoutValidation("x-rpc-client_type", "5");
        request.Headers.TryAddWithoutValidation("x-rpc-device_id", settings.MihoyoDeviceId.ToUpperInvariant());
        request.Headers.TryAddWithoutValidation("x-rpc-device_fp", settings.MihoyoDeviceFp);
        request.Headers.TryAddWithoutValidation("DS", DynamicSecret(query));
        request.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120 Safari/537.36");
        var path = new Uri(url).AbsolutePath;
        if (path.Contains("/genshin/") || path.Contains("/hkrpg/"))
        {
            request.Headers.Remove("x-rpc-app_version"); request.Headers.TryAddWithoutValidation("x-rpc-app_version", "2.63.1");
            request.Headers.TryAddWithoutValidation("Origin", "https://webstatic.mihoyo.com");
            request.Headers.Referrer = new Uri("https://webstatic.mihoyo.com/");
            request.Headers.TryAddWithoutValidation("X-Requested-With", "com.mihoyo.hyperion");
        }
        var json = await SendMihoyoAsync(request, ct);
        return json["data"]?.AsObject() ?? new();
    }

    private async Task<JsonObject> WidgetGetAsync(string url, GameId game, string cookie, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.TryAddWithoutValidation("Cookie", cookie);
        request.Headers.TryAddWithoutValidation("x-rpc-app_version", "2.63.1");
        request.Headers.TryAddWithoutValidation("x-rpc-device_id", settings.MihoyoDeviceId.ToUpperInvariant());
        request.Headers.TryAddWithoutValidation("x-rpc-device_fp", settings.MihoyoDeviceFp);
        request.Headers.TryAddWithoutValidation("x-rpc-channel", "appstore");
        request.Headers.TryAddWithoutValidation("x-rpc-device_model", "iPhone10,2");
        request.Headers.TryAddWithoutValidation("x-rpc-device_name", "iPhone");
        request.Headers.TryAddWithoutValidation("x-rpc-sys_version", "16.2");
        if (game == GameId.Genshin)
        {
            request.Headers.TryAddWithoutValidation("x-rpc-client_type", "5");
            request.Headers.TryAddWithoutValidation("DS", WidgetDynamicSecret());
            request.Headers.UserAgent.ParseAdd("Mozilla/5.0 (Linux; Android 11) miHoYoBBS/2.55.1");
        }
        else
        {
            request.Headers.TryAddWithoutValidation("x-rpc-client_type", "2");
            request.Headers.TryAddWithoutValidation("DS", WidgetBodyDynamicSecret());
            request.Headers.UserAgent.ParseAdd("WidgetExtension/231 CFNetwork/1390 Darwin/22.0.0");
        }
        var json = await SendMihoyoAsync(request, ct);
        return json["data"]?.AsObject() ?? new();
    }

    private async Task EnsureDeviceFpAsync(CancellationToken ct)
    {
        if (settings.MihoyoDeviceFpRegistered) return;
        var ext = JsonSerializer.Serialize(new Dictionary<string, object>
        {
            ["userAgent"] = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_2) miHoYoBBS/2.63.1", ["browserScreenSize"] = 243750,
            ["maxTouchPoints"] = 5, ["isTouchSupported"] = true, ["browserLanguage"] = "zh-CN", ["browserPlat"] = "iPhone",
            ["browserTimeZone"] = "Asia/Shanghai", ["webGlRender"] = "Apple GPU", ["webGlVendor"] = "Apple Inc.",
            ["numOfPlugins"] = 0, ["listOfPlugins"] = "unknown", ["screenRatio"] = 3, ["deviceMemory"] = "unknown",
            ["hardwareConcurrency"] = "4", ["cpuClass"] = "unknown", ["ifNotTrack"] = "unknown", ["ifAdBlock"] = 0,
            ["hasLiedResolution"] = 1, ["hasLiedOs"] = 0, ["hasLiedBrowser"] = 0
        });
        var body = new
        {
            seed_id = RandomString(16, "0123456789abcdef"), device_id = settings.MihoyoDeviceId.ToLowerInvariant(), platform = "5",
            seed_time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds().ToString(), ext_fields = ext, app_name = "account_cn", device_fp = settings.MihoyoDeviceFp
        };
        using var request = new HttpRequestMessage(HttpMethod.Post, "https://public-data-api.mihoyo.com/device-fp/api/getFp") { Content = ApiHttp.JsonContent(body) };
        var json = await SendMihoyoAsync(request, ct);
        var data = json["data"]?.AsObject() ?? throw new InvalidOperationException("米游社设备指纹注册失败");
        var fp = data.Text("device_fp") ?? throw new InvalidOperationException("米游社设备指纹注册失败");
        settings.MihoyoDeviceFp = fp;
        settings.MihoyoDeviceFpRegistered = true;
    }

    private static (int, int, int, int, IReadOnlyList<ChecklistItem>) Normalize(GameId game, JsonObject data)
    {
        return game switch
        {
            GameId.Genshin => (data.Int("current_resin"), data.Int("max_resin"), data.Int("finished_task_num"), data.Int("total_task_num"), []),
            GameId.StarRail => (data.Int("current_stamina"), data.Int("max_stamina"), data.Int("current_train_score"), data.Int("max_train_score"), []),
            GameId.Zenless => Zzz(data),
            _ => (0, 0, 0, 0, [])
        };
    }

    private static (int, int, int, int, IReadOnlyList<ChecklistItem>) Zzz(JsonObject data)
    {
        var progress = data["energy"]?["progress"]?.AsObject() ?? new();
        var vitality = data["vitality"]?.AsObject() ?? new();
        var done = data.Text("card_sign") == "CardSignDone";
        return (progress.Int("current"), progress.Int("max"), vitality.Int("current"), vitality.Int("max"),
            [new("scratch-card", "刮刮卡", done, done ? "已完成" : "待完成")]);
    }

    private async Task<JsonObject> SendMihoyoAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var json = await ApiHttp.SendAsync(_client, request, ct);
        EnsureMihoyoSuccess(json);
        return json;
    }

    private static void EnsureMihoyoSuccess(JsonObject json)
    {
        var code = json.Int("retcode");
        if (code == 0) return;
        var message = json.Text("message") ?? "米游社请求失败";
        if (code is -100 or -101 or 10001 or 10102 || message.Contains("登录")) throw new UnauthorizedAccessException("米游社登录已失效");
        if (code is 1034 or 10035 or 10041 or 5003) throw new InvalidOperationException("需要完成米游社人机验证");
        throw new InvalidOperationException(message);
    }

    private void AddAppQrHeaders(HttpRequestMessage request, string device)
    {
        request.Headers.UserAgent.ParseAdd(QrUserAgent);
        foreach (var (key, value) in new Dictionary<string, string>
        {
            ["x-rpc-app_id"] = QrAppId, ["x-rpc-app_version"] = QrVersion, ["x-rpc-account_version"] = QrVersion,
            ["x-rpc-sdk_version"] = QrVersion, ["x-rpc-client_type"] = "3", ["x-rpc-game_biz"] = "bbs_cn",
            ["x-rpc-device_id"] = device, ["x-rpc-device_fp"] = QrDeviceFp, ["x-rpc-device_model"] = "Mi 14",
            ["x-rpc-device_name"] = "GamePulse Windows"
        }) request.Headers.TryAddWithoutValidation(key, value);
    }

    private static void AddWebQrHeaders(HttpRequestMessage request, string device)
    {
        request.Headers.TryAddWithoutValidation("x-rpc-app_id", QrAppId);
        request.Headers.TryAddWithoutValidation("x-rpc-client_type", "4");
        request.Headers.TryAddWithoutValidation("x-rpc-game_biz", "bbs_cn");
        request.Headers.TryAddWithoutValidation("x-rpc-device_fp", QrDeviceFp);
        request.Headers.TryAddWithoutValidation("x-rpc-device_id", device);
    }

    private static string CookiesFrom(HttpResponseMessage response)
    {
        if (!response.Headers.TryGetValues("Set-Cookie", out var values)) return "";
        return string.Join("; ", values.Select(x => x.Split(';', 2)[0]));
    }

    private static string NormalizeCookie(string cookie)
    {
        var values = ParseCookie(cookie);
        Alias(values, "ltoken_v2", "ltoken");
        Alias(values, "ltuid_v2", "ltuid", "stuid", "login_uid", "account_id");
        Alias(values, "account_id_v2", "account_id", "ltuid", "stuid", "login_uid");
        Alias(values, "account_mid_v2", "mid");
        Alias(values, "cookie_token_v2", "cookie_token");
        return FormatCookie(values);
    }

    private static Dictionary<string, string> ParseCookie(string cookie) => cookie.Split(';', StringSplitOptions.RemoveEmptyEntries)
        .Select(x => x.Trim().Split('=', 2)).Where(x => x.Length == 2).GroupBy(x => x[0]).ToDictionary(x => x.Key, x => x.Last()[1]);
    private static string FormatCookie(Dictionary<string, string> values) => string.Join("; ", values.OrderBy(x => x.Key).Select(x => $"{x.Key}={x.Value}"));
    private static string Value(Dictionary<string, string> values, params string[] keys) => keys.Select(x => values.GetValueOrDefault(x)).FirstOrDefault(x => !string.IsNullOrWhiteSpace(x)) ?? "";
    private static void Alias(Dictionary<string, string> values, string source, params string[] targets)
    {
        if (!values.TryGetValue(source, out var value)) return;
        foreach (var target in targets) values.TryAdd(target, value);
    }

    private static string DynamicSecret(Dictionary<string, string> query)
    {
        var t = DateTimeOffset.UtcNow.ToUnixTimeSeconds(); var r = RandomNumberGenerator.GetInt32(100001, 200001);
        var q = string.Join("&", query.OrderBy(x => x.Key).Select(x => $"{x.Key}={x.Value}"));
        return $"{t},{r},{Md5($"salt=xV8v4Qu54lUKrEYFZkJhB8cuOh9Asafs&t={t}&r={r}&b=&q={q}")}";
    }
    private static string WidgetDynamicSecret()
    {
        var t = DateTimeOffset.UtcNow.ToUnixTimeSeconds(); var r = RandomString(6, "abcdefghijklmnopqrstuvwxyz0123456789");
        return $"{t},{r},{Md5($"salt=9ttJY72HxbjwWRNHJvn0n2AYue47nYsK&t={t}&r={r}")}";
    }
    private static string WidgetBodyDynamicSecret()
    {
        var t = DateTimeOffset.UtcNow.ToUnixTimeSeconds(); var r = RandomNumberGenerator.GetInt32(100000, 200001);
        return $"{t},{r},{Md5($"salt=t0qEgfub6cvueAPgR5m9aQWWVciEer7v&t={t}&r={r}&b=&q=")}";
    }
    private static string Md5(string input) => Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(input))).ToLowerInvariant();
    private static string RandomString(int length, string alphabet) => string.Concat(Enumerable.Range(0, length).Select(_ => alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)]));
    private static string QrUserAgent => $"Mozilla/5.0 miHoYoBBS/{QrVersion} Capture/2.2.0";
}

public sealed class MihoyoStatusService(MihoyoClient client, string cookie, IReadOnlySet<GameId> allowed) : IStatusService
{
    public async Task<IReadOnlyList<GameStatus>> FetchAsync(CancellationToken cancellationToken = default)
    {
        var roles = await client.RolesAsync(cookie, cancellationToken);
        var supported = roles.Where(x => x.IsOfficial && Game(x.GameBiz) is { } id && allowed.Contains(id));
        var result = new List<GameStatus>();
        foreach (var role in supported)
        {
            try { result.Add(await client.StatusAsync(role, cookie, cancellationToken)); }
            catch (Exception error)
            {
                var id = Game(role.GameBiz);
                if (id is not null)
                    result.Add(new(id.Value, "体力", null, "每日进度", new(0, 0), [], SessionState.Unavailable, error.Message, DateTimeOffset.Now));
            }
        }
        return result;
    }

    private static GameId? Game(string biz) => biz switch { "hk4e_cn" => GameId.Genshin, "hkrpg_cn" => GameId.StarRail, "nap_cn" => GameId.Zenless, _ => null };
}
