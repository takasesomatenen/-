# VOID — 触覚だけで空間を探すリラックス系プロトタイプ (iOS / SwiftUI)

真っ黒な画面のどこかに、**見えないターゲット**がひとつだけある。
指を滑らせて、振動の強さと質感だけを頼りに、それを探す。

失敗もゲームオーバーもない。探すという行為そのものが体験。
**できれば目を閉じて**プレイしてほしい。

---

## 触覚の設計

| 伝えたいこと | 使う軸 | 挙動 |
|---|---|---|
| **どれくらい近いか** | intensity（強度） | 近いほど強い。`proximity^gamma` の連続階調（既定 gamma = 2.0） |
| **合っているか／外しているか** | sharpness（鋭さ） | 近づいている間は下げて滑らかに（0.05）、遠ざかると上げてざらつかせる（0.95） |
| **掴みどころのなさ** | ゆらぎ | 遠いほどランダムウォークを混ぜて不規則にする |
| **到達** | 専用パターン | トランジェント3連打＋やわらかい余韻。連続振動とは質感をはっきり分ける |

離散的な「レーン」分けはしていない。触覚は段階を弁別しにくく、
連続グラデーションのほうが「熱い／冷たい」の感覚として直感的に効くため。

音は第三の感覚として触覚を補強する。近づくほどピッチが上がり（C#3 → G#4 を対数補間）、
音量も上がる。デチューンした2つのサイン波＋サブオシレータ＋ゆっくりしたLFOの、パッド系の持続音。

## 操作

| 操作 | 動作 |
|---|---|
| 指を置いてスライド | 探索（DragGesture で座標を取得） |
| 3本指タップ | デバッグ表示のトグル |
| 2本指ダブルタップ | タイトルへ戻る |
| タイトルの「VOID」を長押し（1.2秒） | デバッグ表示のトグル（隠しスイッチ） |

デバッグ表示では、ターゲット位置・到達判定円・指の位置・距離・intensity / sharpness の
実測値がリアルタイムで見える。

## 動かし方

```
open haptic-void/HapticVoid.xcodeproj
```

1. TARGETS → HapticVoid → Signing & Capabilities で自分の Team を選ぶ
   （`PRODUCT_BUNDLE_IDENTIFIER` は必要に応じて変更）
2. **実機（iPhone）** を選んで Run

> プロジェクトが開けない場合は `brew install xcodegen && cd haptic-void && xcodegen generate` で
> `project.yml` から再生成できる（同じ構成）。

- iOS 17.0+ / Swift 5 / 依存ライブラリなし
- ポートレート固定・フルスクリーン

## シミュレータでの挙動（重要）

**Core Haptics はシミュレータでは動作しない。** 実機テストが前提。

このプロトタイプは、その前提でフォールバックを入れてある:

- `CHHapticEngine.capabilitiesForHardware().supportsHaptics` を起動時に確認し、
  false ならハプティクス層は**すべて no-op になる**（クラッシュも例外も出ない）
- AVAudioEngine の距離連動サウンドはシミュレータでも普通に鳴るので、
  **ピッチと音量の変化だけでロジックの検証はできる**
- タイトル画面に「⚠︎ この端末では触覚が再生されません（音のみで動作します）」と表示され、
  デバッグパネルにも `haptics: unavailable (simulator?)` が出る
- デバッグ表示（3本指タップ）を使えば、距離 → intensity / sharpness のマッピングは
  シミュレータ上でも数値とメーターで確認できる

つまり **シミュレータ = 「音とメーターでロジックを見る」用、実機 = 「触覚を詰める」用**。

なお実機でも、以下の場合は振動しない:
- 低電力モードがオン
- アプリがフォアグラウンドにない（**画面オフ中は触覚も音も止まる。iOSの制約**）
- iPhone 7 以前 / iPad（Taptic Engine 非搭載）

コンセプトの「画面オフでも成立する」は iOS では実現できないため、代わりに
真っ黒な画面＋`isIdleTimerDisabled = true`（自動ロックを止める）で、
目を閉じたまま中断されない状態を作っている。

## パラメータ調整

数値はすべて `HapticVoid/Core/Tuning.swift` に集約してある。ロジックには一切ハードコードしていない。

```swift
Tuning.Haptics.intensityGamma       = 2.0   // 大きいほど「近くに来るまで分からない」
Tuning.Haptics.approachingSharpness = 0.05  // 正解方向の質感
Tuning.Haptics.recedingSharpness    = 0.95  // 外している時の質感
Tuning.Haptics.farJitterAmount      = 0.35  // 0 にすると完全に滑らかなグラデーション
Tuning.Space.arrivalRadiusRatio     = 0.055 // 到達判定の広さ（画面短辺比）
Tuning.Space.senseRangeRatio        = 0.80  // 触覚が反応する最大距離（対角線比）
Tuning.Audio.enabled                = true  // 触覚だけの体験を試すときは false
```

### おすすめの詰め方

1. まず `farJitterAmount = 0` かつ `Audio.enabled = false` にして、
   **強度グラデーションだけ**で「近さ」が分かるか確かめる
2. `intensityGamma` で探索の難易度と達成感のバランスを取る
3. そのうえで sharpness の軸（`approachingSharpness` / `recedingSharpness` /
   `approachRateFullScale`）を足し、方向情報が混乱を生まないか確認する
4. 最後にゆらぎと音を戻す

## 構成

```
HapticVoid/
├─ HapticVoidApp.swift          アプリ本体。scenePhase で触覚/音のライフサイクルを管理
├─ Core/
│  ├─ Tuning.swift              全チューニングパラメータ（ここだけ触れば調整できる）
│  ├─ MathHelpers.swift         クランプ / 補間 / 時定数ベースの指数平滑化
│  ├─ DisplayLinkDriver.swift   CADisplayLink による最大120Hzの更新ティック
│  └─ ExplorationEngine.swift   距離 → intensity/sharpness のマッピングとラウンド進行
├─ Haptics/
│  └─ HapticsController.swift   CHHapticEngine / 連続パターン / Dynamic Parameters
├─ Audio/
│  └─ AudioController.swift     AVAudioSourceNode によるサイン波パッドと到達チャイム
└─ Views/
   ├─ RootView.swift            画面遷移と隠しジェスチャ
   ├─ TitleView.swift           タイトル
   ├─ ExplorationView.swift     真っ黒な探索画面（DragGesture）
   ├─ DebugOverlay.swift        開発用の可視化
   └─ MultiFingerTapCatcher.swift  ウインドウに直接付ける複数指タップ認識
```

### 実装メモ

- 連続触覚は**1本の無限ループパターンを鳴らしっぱなし**にして、Dynamic Parameters
  （`hapticIntensityControl` / `hapticSharpnessControl`）だけを書き換えている。
  毎回パターンを作り直すと途切れてグラデーションにならないため。
- `hapticSharpnessControl` は絶対値ではなく**イベント鋭さへの加算オフセット**（-1...1）。
  パターン側の基準値を 0.5 に置き、`目標値 - 0.5` を送ることで絶対値指定に見せている。
- 指が静止すると DragGesture のイベントが止まるので、平滑化とフェードは
  CADisplayLink の固定ティックで回している。
- すべての平滑化は `exp(-dt/tau)` ベース。60Hz と 120Hz で体感が変わらない。
