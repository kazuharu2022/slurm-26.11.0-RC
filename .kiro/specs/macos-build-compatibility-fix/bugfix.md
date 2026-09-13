# Bugfix Requirements Document

## Introduction

本仕様は、SchedMD/Slurm の現行ソースに残る macOS/Darwin と Apple ld64 の間の、実証済みかつ限定的なビルド互換性不具合を修正するための要件を定義する。対象ベースラインは commit `a44a5b8cd1704890c183b7dc44984ab1c2e7a519`（`slurm-25-05-0-1-8822-ga44a5b8cd1`）、Apple Silicon arm64、macOS 26.5.1（Darwin 25.5.0）、Apple Clang 21.0.0、Apple ld64 build 1267 である。受け入れ検証では、Slurm が要求する外部ビルド依存関係が別途満たされていることを前提とする。

本書における runtime-search-path 値 `P` と、2.5 および 3.1 を含むその値を継承するすべての runtime-search-path 条件は、既存の Slurm Autotools/Make/compiler-driver pipeline が単一の path value として扱える supported path domain に限定して解釈し、この domain は通常の absolute path、nested path、ならびに英数字、slash（`/`）、dot（`.`）、underscore（`_`）、hyphen（`-`）等からなる既存の一般的な configured path を含む一方、comma、ASCII whitespace、または shell quoting/control semantics を必要とする特殊 path への新規サポートを含まない。

**対象範囲:** Apple toolchain が拒否することを再現できた runtime search path 引数、埋め込み参照テキスト生成、GNU ld 固有オプションの選択を、各toolchainの意味を保ったまま正しく選択できる状態にする。変更は、これらの阻害要因とその回帰検証に必要な最小範囲に限定する。

**非目標:** macOS 上でのSlurm全体、クライアント群、`slurmd`、`slurmstepd`、ジョブ実行、plugin動作を完成または保証することではない。dyld上のplugin runtime state共有、Linux固有APIの互換実装、CPU affinity、cgroup、process tracking、job accounting、UID/GID切替、authentication、Apple GPU/GRESも本bugfixの対象外とする。特に、未対応APIに成功を返すstubを追加せず、ビルド成功をmacOSの運用サポート表明として扱わない。

## Bug Analysis

### Current Behavior (Defect)

Darwin/arm64 上のビルド操作 `X` に対する bug condition `C(X)` は、Apple Clang と Apple ld64 が選択され、次の 1.1 から 1.3 のいずれかについて、記載された入力条件、生成された Apple ld64 呼び出しに含まれる記載どおりの非対応オプション、および Apple ld64 がそのオプションを拒否したことに起因する非ゼロ終了がすべて成立する場合に限り成立する。コンパイル段階の失敗、入力ファイルの欠落、または記載された非対応オプションの拒否に起因しないリンカー失敗は `C(X)` に含めない。Apple ld64 build 1267 が各オプションを unknown option として識別する診断は baseline 再現証拠として保持するが、診断の正確な文言は `C(X)` の成立条件としない。

1.1 WHEN all compilation stages for an affected Darwin/arm64 target succeed, a non-empty runtime search path is configured, and Apple Clang passes that path to Apple ld64 as the single argument `-rpath=<path>`, THE system SHALL return a non-zero build-operation result caused by Apple ld64 rejecting that argument as unsupported, provide a diagnostic indicating the rejected argument, and leave the requested artifact absent or unchanged from its pre-operation state.

1.2 WHEN existing readable command-reference or usage text is selected for embedding on Darwin/arm64 and the artifact-generation invocation reaches Apple ld64 with both GNU-only option forms `-z noexecstack` and `--format=binary`, THE system SHALL return a non-zero artifact-generation result caused by Apple ld64 rejecting at least one of those option forms as unsupported, provide a diagnostic indicating the rejected option form, and leave the requested artifact absent or unchanged from its pre-operation state.

1.3 WHEN all compilation stages for an affected Darwin/arm64 target succeed and Apple Clang passes GNU ld option `--no-as-needed` to Apple ld64, THE system SHALL return a non-zero build-operation result caused by Apple ld64 rejecting that option as unsupported, provide a diagnostic indicating the rejected option, and leave the requested artifact absent or unchanged from its pre-operation state.

1.4 WHEN build-system source files are regenerated or an affected rule is changed and the existing regression suite is subsequently run on Darwin/arm64 with Apple Clang and Apple ld64, THE system SHALL execute zero Darwin/arm64 regression tests for each linker operation in 1.1 through 1.3 that both invoke that operation and verify a zero result and production of its requested artifact.

### Expected Behavior (Correct)

2.1 WHEN a Darwin/arm64 runtime-search-path operation supplies a configured non-empty path P through Apple Clang to Apple ld64, THE system SHALL complete with zero exit status, produce the requested Mach-O artifact, pass no single Apple ld64 argument beginning with `-rpath=`, and record at least one runtime search-path entry in the artifact whose complete path value is byte-for-byte equal to P.

2.2 WHEN a Darwin/arm64 reference-embedding operation consumes an existing readable command-reference or usage-text payload, THE system SHALL complete with zero exit status, produce the requested Mach-O embedded-reference artifact, pass no consecutive Apple ld64 arguments equal to `-z` and `noexecstack`, and pass no Apple ld64 argument equal to `--format=binary`.

2.3 WHEN a Darwin/arm64 target reaches the affected dependency-retention link operation with expected set D, where D is the set of recorded dependency identifiers of the dynamic libraries selected by that operation for retention, THE system SHALL complete with zero exit status, produce the requested Mach-O artifact, pass no Apple ld64 argument equal to `--no-as-needed`, and include every member of D among the artifact's recorded direct load dependencies.

2.4 IF an automated Darwin regression check observes an Apple ld64 argument beginning with `-rpath=`, consecutive Apple ld64 arguments equal to `-z` and `noexecstack`, an Apple ld64 argument equal to `--format=binary` or `--no-as-needed`, or an unmet artifact contract from 2.1, 2.3, or 2.6, THEN THE system SHALL return a non-zero check result that identifies every affected operation and every observed forbidden option form or unmet artifact contract.

2.5 WHEN the three baseline reproductions corresponding to 1.1 through 1.3 are run independently with their direct input prerequisites present and their requested output artifacts absent on Apple Clang 21.0.0 and Apple ld64 build 1267, THE system SHALL return zero exit status for each corrected operation, create all three requested artifacts, and satisfy every applicable contract in 2.1, 2.2, 2.3, and 2.6.

2.6 WHEN a Darwin embedded-reference artifact created from a non-empty source payload S of N bytes is inspected and subjected to a link check using the existing consumer's payload-symbol references, THE system SHALL define the start and end symbols with the exact names referenced by that consumer, resolve the start symbol to the first byte of S, resolve the end symbol to an address N bytes after the start symbol, preserve at each offset i from 0 through N−1 the byte value at offset i in S, and complete the consumer-symbol link check with zero exit status and no unresolved reference to either boundary symbol.

2.7 WHEN out-of-tree Darwin validation invokes an affected generated rule or substitutes a limited reproduction for that rule, THE system SHALL evaluate each corrected operation independently, accept the limited reproduction as equivalent only when it preserves the corrected generated rule's toolchain, operation-specific input bytes and values, effective tool arguments, and output artifact type while allowing only filesystem locations and unrelated surrounding build steps to differ, and classify an operation blocked before invocation by an unrelated portability or external-dependency failure as not reached rather than failed.

2.8 THE system SHALL determine acceptance solely from the runtime-search-path, reference-embedding, and dependency-retention operations and artifact contracts in 2.1 through 2.7, without requiring a successful full macOS build or any plugin runtime execution and without adding success-returning stubs, altering unrelated API or runtime semantics, or claiming broader macOS support.

### Unchanged Behavior (Regression Prevention)

3.1 WHEN the changed runtime-search-path rule is executed with a GNU/Linux toolchain using the inputs, configuration, toolchain version, and environment of the target baseline commit, THE system SHALL produce an artifact with the same ordered runtime search-path entries as the baseline artifact.

3.2 WHEN the changed reference-embedding rule is executed with a GNU/Linux toolchain using the source payload, configuration, toolchain version, and environment of the target baseline commit, THE system SHALL produce an artifact containing every source byte in the baseline order between the same consumer-required start and end symbols, with the same symbol names and linkage as the baseline artifact.

3.3 WHEN the existing consumer uses the artifact produced by the changed reference-embedding rule with the options, input, locale, and environment of the target baseline commit, THE system SHALL present user-visible content identical to the baseline in text, ordering, and line breaks.

3.4 WHEN the changed dependency-retention rule is executed with a GNU/Linux toolchain using the inputs, configuration, toolchain version, and environment of the target baseline commit, THE system SHALL produce an artifact whose recorded link dependencies are identical in identity and order to those of the baseline artifact.

3.5 WHEN the project-prescribed bootstrap procedure is executed from a clean patched source tree using the prescribed bootstrap tool versions and environment, THE system SHALL complete the procedure without modifying the patched canonical build-system definitions or any tracked generated output included in the patch.

3.6 WHEN the patch diff is compared with the target baseline commit, THE system SHALL contain changed lines only in the canonical build-rule definitions for the three corrected operations, outputs generated directly from those definitions, and regression checks that directly exercise those operations.

3.7 WHEN the patch diff is compared with the target baseline commit, THE system SHALL contain zero changed lines in plugin-loader implementation, plugin interfaces, plugin runtime-state behavior, compatibility shims, or platform API behavior not exercised by the three corrected build operations.

3.8 WHEN the patch diff is compared with the target baseline commit, THE system SHALL contain zero changed lines in security, credential, privilege, authentication, Slurm protocol, public API or ABI, command-option, or configuration-interpretation implementation or declarations.

3.9 WHEN the results of the three corrected Darwin build operations are reported, THE system SHALL identify macOS as unsupported and SHALL NOT characterize those results as validation of macOS clients, daemons, plugins, job execution, runtime behavior, or dyld plugin-state inheritance.

3.10 IF a portability failure or missing external build dependency prevents a surrounding macOS build from reaching a corrected generated rule, THEN THE system SHALL report the failure separately from that corrected operation, SHALL NOT treat the failure as a regression of that operation, and SHALL accept individual execution of the generated rule or a limited reproduction with the same inputs and effective arguments as sufficient validation without requiring a full-platform build or runtime test suite.
