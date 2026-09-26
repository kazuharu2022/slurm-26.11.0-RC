# macOS Slurm検証記事 品質レビュー

- 対象: `doc/slurm_macos_porting_change_summary.md`
- 判定: `PUBLICATION_CANDIDATE_DRAFT`
- 理由: 実測と失敗履歴は記事化できる水準で、identity fail-openは2026-09-22のproduction
  clean candidate runtimeで解消した。固定HEADからのMac clean rebuildとUbuntu分離buildも完了した。
  TLSは再修正版によるbounded runtime、accounting、負例、復旧、試験用active artifactのarchive退避・削除、
  最終`tls/none` smokeまで完了した。archive内の試験鍵は再利用せず、再有効化時は新規証明書を発行する。
  SMD-102のLinux codegen/runtime regressionは2026-09-26に完了した。memory enforcementと
  移植patch series全体のclean reproductionが未解決であり、
  production-ready記事とはしない。

## Evidence Gate

| 項目 | 判定 | 根拠 |
|---|---|---|
| Research Question | PASS | task lifecycle、境界、GPU、異種architectureを問いとして明記 |
| 仮説・反証条件 | PASS | daemon crash、誤identity、process残留、silent failureを反証条件化 |
| 検証計画 | PASS | 6群61項目のmatrixを提示 |
| 実環境・version | PASS | macOS、Ubuntu、Slurm、toolchainを記録 |
| 実行条件 | PASS | Python、uv、MLXおよびhost別条件を記録 |
| command/code | PASS | build、job、accounting、process確認のcommandを掲載 |
| 生データ・log | PASS | stdout/stderr、sacct、PID、resource値をEvidenceへ対応付け |
| 分析・考察 | PASS | CPU、memory、GPU、PGID、configless、IPv6、TLSを別評価 |
| 一次情報 | PASS | SchedMD公式documentとMLX一次情報を参照 |
| 制約・未確認 | PASS | Missing Evidenceを9項目で列挙 |
| 独自価値 | PASS | Apple Silicon実機61項目、24時間soak、失敗・復旧を記録 |
| 未検証の非昇格 | PASS | SMD-407はTLS runtime、archive cleanup、将来の新規証明書発行を分離し、SMD-401と前提不足項目もPASSへ丸めない。SMD-102はJobs 620/621に加えclean Jobs 622/623とroot log監査後だけPASSを維持 |

## E-E-A-Tレビュー

| 項目 | 点 | 評価 |
|---|---:|---|
| Experience | 2 | 実機job、長時間試験、失敗、復旧を含む |
| Expertise | 2 | OS依存、process/resource境界、pluginの意味を説明 |
| Authoritativeness | 2 | 主要仕様をSchedMD公式documentへ接続 |
| Trustworthiness | 2 | `PASS_STAGING`、unsupported、blocked、failureを分離 |
| Originality | 2 | M5 Max、Metal GRES、mixed arch、IPv6/TLSの実測 |
| Reproducibility | 1 | SMD-102は固定HEAD clean build、Linux分離build、source commit provenance、正規化codegen一致、Jobs 730〜732のruntimeまで完了したが、移植patch series全体のclean reproductionは未完 |
| Usefulness | 2 | 再現check、失敗TIPS、導入blockerを提示 |
| Evidence | 2 | job/step accounting、PID、queue、hashで結論を支持 |
| Clarity | 2 | Research Questionから結果、限界、結論まで対応 |
| **合計** | **17/18** | 完成度は高いが公開前の再現性課題を残す |

## 改善すべきEvidence

1. `完了`: 固定HEADへSMD-102修正を適用し、Mac configure/build/stage/installを再現した。
2. `完了`: Ubuntu x86-64分離treeのconfigure/build/checkに加え、raw codegen差をsource line metadataへ限定し、正規化assembly/object一致、production workerの正常・期待失敗・cancel Jobs 730〜732、accounting、資源回収を確認した。
3. `完了（TLS runtimeとcleanup）`: Darwin `/dev/fd/N`問題とLibreSSL `openssl req -new`を修正し、両hostへbackup付き導入。Ubuntu TLS active中の旧client拒否、修正版Mac TLS client接続5/5、Mac daemon登録、CPU/direct srun/Apple GPU/mixed-node、全accounting、未信頼CA負例、両host復旧を確認した。active artifact/stateはroot-only archive後に削除し、最終tls/none Jobs 638/639もPASSした。archive内試験鍵は再利用せず、将来TLS再有効化時は新規証明書を発行する。
4. `完了`: clean build由来binaryをproductionで読み戻し、SMD-102の不一致Job 622・一致Job 623を再実行した。
5. `完了（source commit provenance）`: SMD-102修正をcommit `ce597ed8fd`へ固定し、親commit、対象source SHA-256、clean build source、live `origin/master`を対応付けた。

このレビューは記事品質の判定であり、macOS Slurmのproduction承認ではない。
