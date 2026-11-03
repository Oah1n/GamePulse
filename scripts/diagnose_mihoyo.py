#!/usr/bin/env python3
"""Diagnose GamePulse's Miyoushe session without printing credentials."""

import asyncio
import subprocess
import sys

import genshin


def read_cookie() -> str:
    result = subprocess.run(
        [
            "/usr/bin/security",
            "find-generic-password",
            "-s",
            "cn.gamepulse.desktop",
            "-a",
            "mihoyoCookie",
            "-w",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


async def main() -> int:
    try:
        cookie = read_cookie()
    except subprocess.CalledProcessError:
        print("keychain: missing")
        return 2

    print(f"keychain: present ({len(cookie)} bytes)")
    client = genshin.Client(cookie, region=genshin.Region.CHINESE, lang="zh-cn")

    try:
        accounts = await client.get_game_accounts()
    except Exception as exc:
        print(f"roles: failed: {type(exc).__name__}: {exc}")
        return 3

    supported = [account for account in accounts if account.game_biz in {"hk4e_cn", "hkrpg_cn", "nap_cn"}]
    print("roles:", ", ".join(f"{a.game_biz}@{a.region}" for a in supported) or "none")

    for account in supported:
        try:
            if account.game_biz == "hk4e_cn":
                note = await client.get_genshin_notes(account.uid)
                print(f"genshin: resin={note.current_resin}/{note.max_resin} daily={note.completed_commissions}/{note.max_commissions}")
            elif account.game_biz == "hkrpg_cn":
                note = await client.get_starrail_notes(account.uid)
                print(f"starrail: stamina={note.current_stamina}/{note.max_stamina} daily={note.current_train_score}/{note.max_train_score}")
            elif account.game_biz == "nap_cn":
                note = await client.get_zzz_notes(account.uid)
                print(f"zenless: energy={note.battery_charge.current}/{note.battery_charge.max} daily={note.engagement.current}/{note.engagement.max}")
        except Exception as exc:
            print(f"{account.game_biz}: failed: {type(exc).__name__}: {exc}")

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
