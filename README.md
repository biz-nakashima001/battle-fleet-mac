# 海戦司令部 (Battle Fleet)

SwiftUI で作成した macOS 向けの海戦ゲームです。

## 開発環境

- Xcode で `BattleFleet.xcodeproj` を開く
- `BattleFleet` スキームを選び、My Mac を実行先にして起動する
- macOS 13 以降を対象にビルド

## ゲーム内容

- 10×10、15×15、20×20 の盤面を選択
- CPU の難易度は LV1〜LV10
- 戦艦、巡洋艦、駆逐艦、潜水艦、哨戒艇の5隻で対戦
- 自艦隊はゲーム開始前に自動配置され、再配置も可能

ゲーム状態とCPUの思考処理は `BattleFleet.swift` にあります。
