# TZSync

> macOS 菜单栏工具：检测出口时区，同步终端时区，并可经系统授权调整 macOS 时区。

**技术栈：** Swift · AppKit · macOS systemsetup

**使用边界：** 不改变出口 IP；代理检测失败可能回退直连。

---

讓 **Mac 的時區跟隨你的代理出口 IP** 的選單列小工具。像瀏覽器插件一樣常駐在右上角、手動開關。

`notme` 擴充只改**瀏覽器**看到的時區；TZSync 補上另外兩層：

| 你用 | 時區來自 | TZSync 對應功能 |
| --- | --- | --- |
| 終端程式（Claude Code 等，讀 OS 的 `TZ`） | shell 的 `TZ` | **啟用終端時區同步**（免密） |
| 選單列時鐘 / 行事曆 / 所有 App | 系統時區 | **同步系統時區**（需密碼授權） |

## 編譯 & 啟動

```bash
cd TZSync
bash build.sh        # 用命令列 swiftc 編出 TZSync.app（免 Xcode IDE）
open TZSync.app      # 右上角出現 🕐 圖示
```

首次開啟若被 Gatekeeper 攔（未簽名），到「系統設定 › 隱私權與安全性」按「仍要打開」，或右鍵 → 打開。

## 用法

點右上角 🕐：

- **狀態列**：`出口: <時區> ｜ 系統: <時區> ✓/✗ 是否一致`。
- **啟用終端時區同步（免密）**：勾選後在 `~/.zshrc`（與 `~/.bashrc`，若存在）寫入一段
  有標記的 `export TZ="<出口時區>"`。**開新終端**後 `echo $TZ` 生效。取消勾選 = 移除該區塊。
- **同步系統時區（需授權）**：彈 macOS 原生密碼框，用 `systemsetup -settimezone` 改整個系統時區。
- **恢復預設時區（<原值>）**：一鍵回到改動前的原狀 —— 關掉終端同步、清掉強制指定，並把系統時區
  改回原始值（需授權）。原始值在第一次改系統時區前自動記錄，也可用 `--set-default <tz>` 指定。
- **強制指定時區**：不想自動跟隨時，可鎖定某個美國時區（LA/丹佛/芝加哥/紐約）。選「自動」恢復跟隨出口。
- **立即重新偵測**：重抓出口時區。每 6 小時也會自動重抓一次（僅更新終端層）。

出口時區偵測走代理 `127.0.0.1:10808`（xray），多 provider 備援（ipwho.is → ipapi.co → ipinfo.io →
reallyfreegeoip）；走代理全失敗時退回直連（拿到的是本機真實出口，狀態列標「直連」）。

## 卸載

- 退出 App（選單「退出 TZSync」）。
- 若曾啟用終端同步：先在選單取消勾選（會清掉 profile 區塊），或手動刪 `~/.zshrc` 裡
  `# >>> TZSync managed >>>` 到 `# <<< TZSync managed <<<` 之間那幾行。
- 刪掉 `TZSync.app`。系統時區若改過，用「同步系統時區」改回或到系統設定手動調。

## headless 自測（給命令列驗收）

```bash
TZSync.app/Contents/MacOS/TZSync --detect          # 走代理偵測，印 timezone/country/ip/provider
TZSync.app/Contents/MacOS/TZSync --detect-direct   # 直連偵測
TZSync.app/Contents/MacOS/TZSync --status          # 目前系統時區 / 終端同步狀態
TZSync.app/Contents/MacOS/TZSync --set-default <tz> # 指定「恢復預設」用的原始時區
TZSync.app/Contents/MacOS/TZSync --restore          # 關終端層並印出預設（系統層改回需選單授權）
```

## 誠實的限制

- 這只改**本機報告的時區**。帳號真正的**出口 IP** 由你的代理決定，TZSync 改不了它 ——
  IP 側的地理檢查仍看代理出口。要真正換地區只能換代理落地。這點與 `notme` / `claude-tz` 一致。
- 系統時區同步每次都要密碼授權（刻意不配免密 sudoers，換取安全）。
- 偵測需代理在跑；代理沒開時會退回直連的真實出口，或用你「強制指定」的值。

<!-- 更新备注：YANG KAISEN，2026-11-11；改写与核对依据见工作区变更记录。 -->
