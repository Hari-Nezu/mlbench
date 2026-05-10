# mlbench

Phase A3 (Core ML モデル導入) における推論パフォーマンスを検証するためのベンチマークツールです。

## 目的

Core ML モデルのロード時間や、指定した画像に対する反復推論時間を計測し、非同期パイプラインにおけるメインスレッドへの影響や許容時間を事前評価するために用います。

## 動作環境

- Swift 6.3 / 言語モード 6
- macOS 26 (Sequoia 以降の API を前提)

## 使い方

ルートディレクトリの `mlbench` フォルダ内で以下のコマンドを実行します。

```bash
cd mlbench
swift run mlbench [オプション] <画像ファイルまたはディレクトリパス>
```

引数にディレクトリを渡した場合、そのディレクトリ内にある最初の画像 (`.jpg`, `.png`, `.arw` など) を自動で選択してテストに使用します。

### オプション一覧

| オプション           | 説明                                                                        | デフォルト                             |
| -------------------- | --------------------------------------------------------------------------- | -------------------------------------- |
| `--model <path>`     | Core ML モデルのパス (`.mlmodel`, `.mlpackage`, `.mlmodelc`)                | なし (組み込み VNClassifyImageRequest) |
| `--vision <types>`   | Vision リクエストをカンマ区切りで指定 (後述)                                | なし                                   |
| `--iterations <num>` | 推論の反復回数                                                              | `10`                                   |
| `--compute <unit>`   | 推論プロセッサ: `all`, `cpu`, `gpu`/`cpuandgpu`, `ane`/`cpuandneuralengine` | `all`                                  |
| `--resize <pixels>`  | 長辺の最大ピクセル数にリサイズしてからベンチマーク                          | なし (元解像度)                        |

### `--vision` で指定できるリクエスト

| キー       | Vision リクエスト                              |
| ---------- | ---------------------------------------------- |
| `face`     | `VNDetectFaceLandmarksRequest`                 |
| `quality`  | `VNDetectFaceCaptureQualityRequest`            |
| `saliency` | `VNGenerateAttentionBasedSaliencyImageRequest` |
| `classify` | `VNClassifyImageRequest`                       |
| `feature`  | `VNGenerateImageFeaturePrintRequest`           |

## 実行例

### 基本: 組み込みモデルのベースライン

```bash
swift run mlbench ../rawbench/SamplePic/
```

### Vision パイプラインベンチマーク

5 種類の Vision リクエストを複合で計測:

```bash
swift run mlbench --vision face,quality,saliency,classify,feature --iterations 20 ../rawbench/SamplePic/
```

### リサイズして計測

実運用では RAW 全体 (6000x4000) ではなく、埋め込み JPEG プレビュー (1024〜2048px) で解析する。`--resize` でその条件をシミュレートできる:

```bash
# 長辺1024pxにリサイズしてからベンチマーク
swift run mlbench --vision face,quality,saliency --resize 1024 --iterations 20 ../rawbench/SamplePic/

# 長辺2048pxにリサイズ
swift run mlbench --vision face,quality,saliency,classify,feature --resize 2048 --iterations 20 ../rawbench/SamplePic/
```

### カスタムモデルを ANE で 50 回テスト

```bash
swift run mlbench --model /path/to/AestheticScore.mlpackage --compute ane --iterations 50 ../rawbench/SamplePic/
```

### SDカード上の画像を直接指定

```bash
swift run mlbench --vision face,quality --iterations 10 /Volumes/Untitled/DCIM/12960202/DSC00943.ARW
```

## 出力例

### カスタムモデルベンチマーク

```
Found 3 images. Will use the first one for iteration benchmark.
Image loaded: test_photo.jpg (4000x3000)
Loading custom model from /path/to/Model.mlpackage...
Compiling model...
Compute Units: cpuAndNeuralEngine
Model loaded in 150.23 ms
Starting benchmark with 10 iterations...
Iter 1: 34.50 ms
Iter 2: 12.10 ms
...
--- Benchmark Results ---
Model: Model.mlpackage
Resolution: 4000x3000
Min:    11.80 ms
Max:    34.50 ms
Avg:    13.45 ms
Median: 12.10 ms
-------------------------
```

### Vision パイプライン + リサイズ

```
Image loaded: DSC01042.ARW (6000x4000)
Resized to 1024x683 (max 1024) in 12.34 ms

Vision Pipeline Benchmark
  Requests: VNDetectFaceLandmarksRequest + VNClassifyImageRequest
  Iterations: 10

  Iter  1:  individual sum =  120.34 ms  |  combined =   45.67 ms
  Iter  2:  individual sum =   35.12 ms  |  combined =   22.45 ms
  ...

--- Vision Pipeline Results ---
Resolution: 1024x683

Per-request breakdown (individual execution):
  VNDetectFaceLandmarksRequest   Min:  12.34  Max:  80.12  Avg:  18.56  Median:  14.23 ms
  VNClassifyImageRequest         Min:  15.67  Max:  40.22  Avg:  18.12  Median:  16.45 ms

Combined pipeline (all requests in single perform call):
  Combined                       Min:  20.45  Max:  45.67  Avg:  23.89  Median:  22.45 ms
-------------------------------
```

### `--vision` の出力について

各イテレーションで 2 通り計測します:

1. **individual sum**: 各リクエストを別々の `VNImageRequestHandler` で実行した合計時間
2. **combined**: 全リクエストを 1 つの `perform()` にまとめた時間 (Vision が内部で画像前処理を共有するため高速)

最後のイテレーションでは **observation サマリ** (検出された顔数、分類ラベル、サリエンシーオブジェクト数など) も表示します。

_(最初のイテレーション (Iter 1) はウォームアップなどの影響で遅くなる傾向があるため、Median を参考にしてください)_

# mlbench
