# GamePulse Data Bridge v1

## Endpoint

`GET /v1/status`

日期使用 ISO 8601 UTC 格式。`recoverySecondsPerUnit` 是恢复 1 点体力所需秒数；应用会在两次网络刷新之间本地推算当前值。

```json
{
  "generatedAt": "2026-10-25T07:00:00Z",
  "games": [
    {
      "id": "genshin",
      "staminaName": "原粹树脂",
      "stamina": {
        "current": 118,
        "maximum": 200,
        "capturedAt": "2026-10-25T07:00:00Z",
        "recoverySecondsPerUnit": 480
      },
      "dailyName": "每日委托",
      "daily": { "completed": 3, "total": 4 },
      "checklist": [],
      "session": "active",
      "message": null,
      "updatedAt": "2026-10-25T07:00:00Z"
    }
  ]
}
```

## `id`

- `genshin`
- `starRail`
- `zenless`
- `arknights`
- `wutheringWaves`

## `session`

- `active`: 会话有效
- `needsLogin`: 需要用户重新授权
- `unavailable`: 服务或采集器不可用

