using System.Net.Http.Headers;
using System.Net.Http;
using System.Text.Json;
using System.Text.Json.Serialization;
using GamePulse.Windows.Models;

namespace GamePulse.Windows.Services;

public interface IStatusService
{
    Task<IReadOnlyList<GameStatus>> FetchAsync(CancellationToken cancellationToken = default);
}

public sealed class BridgeStatusService(string baseUrl, string bearerToken) : IStatusService
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(20) };

    public async Task<IReadOnlyList<GameStatus>> FetchAsync(CancellationToken cancellationToken = default)
    {
        if (!Uri.TryCreate(baseUrl.TrimEnd('/') + "/v1/status", UriKind.Absolute, out var uri))
            throw new InvalidOperationException("数据桥地址无效");
        using var request = new HttpRequestMessage(HttpMethod.Get, uri);
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (!string.IsNullOrWhiteSpace(bearerToken))
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", bearerToken);
        using var response = await Client.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();
        var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
        var envelope = await JsonSerializer.DeserializeAsync<StatusEnvelope>(stream, JsonOptions, cancellationToken);
        return envelope?.Games ?? throw new InvalidOperationException("数据桥返回了无法识别的数据");
    }

    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };
}

public sealed class DemoStatusService : IStatusService
{
    public Task<IReadOnlyList<GameStatus>> FetchAsync(CancellationToken cancellationToken = default)
    {
        var now = DateTimeOffset.Now;
        IReadOnlyList<GameStatus> games =
        [
            Game(GameId.Genshin, "原粹树脂", 118, 200, 480, "每日委托", 3, 4, now),
            Game(GameId.StarRail, "开拓力", 214, 300, 360, "每日训练", 420, 500, now),
            Game(GameId.Zenless, "电量", 164, 240, 360, "活跃度", 300, 400, now),
            Game(GameId.Arknights, "理智", 93, 135, 360, "日常任务", 8, 10, now),
            Game(GameId.WutheringWaves, "结晶波片", 176, 240, 360, "每日活跃", 80, 100, now)
        ];
        return Task.FromResult(games);
    }

    private static GameStatus Game(GameId id, string staminaName, int current, int maximum,
        double recovery, string dailyName, int completed, int total, DateTimeOffset now) =>
        new(id, staminaName, new StaminaSnapshot(current, maximum, now, recovery), dailyName,
            new DailyProgress(completed, total), [], SessionState.Active, "演示数据", now);
}
