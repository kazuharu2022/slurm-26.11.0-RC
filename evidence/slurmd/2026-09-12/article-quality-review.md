# macOS Slurm検証記事 品質レビュー

- 対象: `doc/slurm_macos_porting_change_summary.md`
- 判定: `PUBLICATION_CANDIDATE_DRAFT`
- 理由: 実測と失敗履歴は記事化できる水準だが、TLS runtime、identity fail-open、
  memory enforcement、clean Linux regressionが未解決であり、production-ready記事とはしない。

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
| 制約・未確認 | PASS | Missing Evidenceを10項目で列挙 |
| 独自価値 | PASS | Apple Silicon実機61項目、24時間soak、失敗・復旧を記録 |
| 未検証の非昇格 | PASS | SMD-102、401、407、前提不足項目をPASSへ丸めていない |

## E-E-A-Tレビュー

| 項目 | 点 | 評価 |
|---|---:|---|
| Experience | 2 | 実機job、長時間試験、失敗、復旧を含む |
| Expertise | 2 | OS依存、process/resource境界、pluginの意味を説明 |
| Authoritativeness | 2 | 主要仕様をSchedMD公式documentへ接続 |
| Trustworthiness | 2 | `PASS_STAGING`、unsupported、blocked、failureを分離 |
| Originality | 2 | M5 Max、Metal GRES、mixed arch、IPv6/TLSの実測 |
| Reproducibility | 1 | driverとEvidenceはあるがclean revision/Linux regressionが未完 |
| Usefulness | 2 | 再現check、失敗TIPS、導入blockerを提示 |
| Evidence | 2 | job/step accounting、PID、queue、hashで結論を支持 |
| Clarity | 2 | Research Questionから結果、限界、結論まで対応 |
| **合計** | **17/18** | 完成度は高いが公開前の再現性課題を残す |

## 改善すべきEvidence

1. clean source revisionからpatch、configure、build、installを再現する。
2. LinuxでDarwin分岐のregressionを実行する。
3. TLS controller ping失敗の原因を特定し、job、accounting、certificate rotationを再試験する。
4. SMD-102をfail-closedへ修正し、異なるnumeric UID/GIDで再試験する。

このレビューは記事品質の判定であり、macOS Slurmのproduction承認ではない。
