# Implementation Plan

## Overview

本計画は、baseline commit `a44a5b8cd1704890c183b7dc44984ab1c2e7a519` で再現する3つのApple ld64 build-operation不具合を、bug condition methodologyで修正する。製品修正はruntime rpath、reference-text object生成、dependency retentionの3領域と、それらのtoolchain選択に必要な最小のbuild-system conditionalに限定する。

修正前に、唯一のstandalone driver `testsuite/macos_build_compatibility.sh` の全ロジックとinterfaceを完成させ、pristine unfixed Darwin baselineからimmutable manifestを取得する。baseline取得後は、fixture、assertion、schema、CLI、hash semanticsを変更しない。Darwin fix evidence、GNU/Linux preservation evidence、generation/scope evidenceは独立branchとして進め、最終checkpointでのみ合流させる。

## Notes

### Execution Policy

- 新規test programは `testsuite/macos_build_compatibility.sh` 1本だけとする。custom harness、helper driver、second driver、custom logger、PBT framework、random corpusを追加しない。
- driverはstandaloneで明示実行し、`testsuite/Makefile.am`を変更しない。Automake suite登録やroot harness追加を完了条件にしない。
- Property checksはfixed fixtureをparameterizeした再現可能なproperty assertionsとして実装する。
- 製品/build-rule変更前にdriverの全5 mode、全fixture、全assertion、manifest schema、CLI/env/status contract、effective-argument capture、interface hashを完成・凍結する。
- immutable Darwin manifest取得後にdriver bytes、fixture input/ID、assertion meaning、schema、CLI/interface、effective-argument capture、failure classificationのいずれかを変更した場合、既存manifestを編集・再hashしてはならない。製品rule未修正のpristine baselineから全fixtureを新しいgenerationとして再取得する。
- evidence rootはabsolute pathで、source tree、build tree、git worktreeの外側に置く。manifest、Linux contracts、results、validation reportをrepositoryへcopy、stage、commitしない。
- actual generated ruleが周辺portability failureまたは外部dependency不足でinvocation前に止まる場合は、対象operationを`not reached: <reason>`と記録する。同じtoolchain、operation input、effective arguments、artifact typeを保つlimited reproductionで個別検証する。
- Linux runner不在またはpreflight failureは`BLOCKED_LINUX_RUNNER_UNAVAILABLE`または理由付き`BLOCKED`である。Darwin evidence作成は継続するが、Linux branchを`not reached`、status 77、PASSへ変換せず、最終completionをblockedにする。
- full macOS build、clients、daemons、plugins、job execution、runtime behavior、dyld plugin-state inheritanceはgateにしない。成功return stub、compatibility shim、runtime/API/security変更を追加しない。

### Frozen Driver Contract

#### Fixed fixture set

baseline manifestのrecord orderとfixture inputsを次で固定する。filesystem locationだけはlogical roleへ正規化できるが、path value、payload bytes、dylib install name、fixture ID、record orderを変更しない。

| Order | Fixture ID | Kind | Frozen input |
|---:|---|---|---|
| 1 | `rpath-absolute` | RuntimeRpath | `P=/opt/slurm/lib/slurm` |
| 2 | `rpath-nested` | RuntimeRpath | `P=/opt/slurm/lib/slurm/plugins-v2` |
| 3 | `reference-text` | EmbeddedReference | `usage.txt`; bytes `75 73 61 67 65 0a` (`usage\n`) |
| 4 | `reference-binary` | EmbeddedReference | `binary.txt`; bytes `00 ff 0a 41 00` |
| 5 | `reference-multidot-certgen` | EmbeddedReference | `certgen.sh.txt`; bytes `63 65 72 74 67 65 6e 0a` (`certgen\n`) |
| 6 | `retention-one-dylib` | DependencyRetention | one strong dylib with `LC_ID_DYLIB=@rpath/libfixture-one.dylib`; pre-link `D` contains that ID |
| 7 | `retention-two-dylib` | DependencyRetention | two ordered strong dylibs with IDs `@rpath/libfixture-one.dylib`, `@rpath/libfixture-two.dylib`; pre-link `D` contains both IDs in operand order |
| 8 | `classification-missing-input` | classification only | missing reference payload; `invocationReached=false`, `C_F=false`, classification `not_reached`; excluded from `B_M` |

The seven bug fixtures must have `C_F=true`; `B_M` must be non-empty and contain RuntimeRpath, EmbeddedReference, and DependencyRetention. Linux preservation uses the same normal/nested paths, text/binary/multi-dot payloads, and known-ID one/two-library fixtures.

#### CLI, modes, and evidence paths

All invocations use this interface:

```text
testsuite/macos_build_compatibility.sh \
  --mode MODE \
  --source-tree ABS_SOURCE_TREE \
  --build-root ABS_BUILD_ROOT \
  --evidence-dir ABS_EVIDENCE_ROOT \
  [--manifest ABS_MANIFEST] \
  [--baseline-contract ABS_BASELINE_CONTRACT]
```

`--source-tree`、`--build-root`、`--evidence-dir`はabsolute path必須とし、evidence directoryがsource/build/git worktree内ならnonzeroで拒否する。

| Mode | Required extra input | Required platform | Success output |
|---|---|---|---|
| `freeze-darwin-baseline` | none | Darwin/arm64 pristine baseline | `<EVIDENCE_ROOT>/darwin/baseline/manifest.json` and `manifest.sha256` |
| `verify-darwin-fix` | `--manifest <.../darwin/baseline/manifest.json>` | Darwin/arm64 patched snapshot | `<EVIDENCE_ROOT>/darwin/patched/results.json` |
| `verify-aggregate-diagnostics` | `--manifest <.../darwin/baseline/manifest.json>` | Darwin/arm64 patched snapshot | `<EVIDENCE_ROOT>/darwin/diagnostics/results.json` |
| `capture-linux-baseline` | none; loads frozen interface metadata from the formal evidence root | GNU/Linux pristine baseline snapshot | `<EVIDENCE_ROOT>/linux/runner-preflight.json`, `baseline/contracts.json`, and `contracts.sha256` |
| `verify-linux-preservation` | `--baseline-contract <.../linux/baseline/contracts.json>` | same GNU/Linux runner, patched snapshot | `<EVIDENCE_ROOT>/linux/patched/results.json` |

Required environment:

- Common: `HOST`, `PATH`, `LC_ALL=C`, `TZ=UTC`, `CC`, `LD`, `NM`, `FILE`.
- Darwin modes: common set plus `OTOOL`.
- Linux modes: common set plus `READELF`, `OBJCOPY`; runner preflight also records `AR`, `AS`, `MAKE`, shell, Autotools, compiler/linker/binutils absolute paths and versions.
- Tool overrides resolve to absolute executables and are recorded. Driver records only the environment allowlist, never secrets or an unbounded environment dump.

Status contract:

- `0`: the requested mode completed every applicable required check and wrote validated evidence atomically.
- nonzero other than `77`: schema/hash/preflight/verification/artifact/aggregate-reporting violation.
- `77`: platform is inapplicable to the explicitly requested mode or caller selected an explicit skip policy.
- Linux runner absence is an orchestration-level required-gate `BLOCKED`, not driver status 77 and not PASS.

Formal evidence paths are:

```text
<EVIDENCE_ROOT>/darwin/baseline/manifest.json
<EVIDENCE_ROOT>/darwin/baseline/manifest.sha256
<EVIDENCE_ROOT>/darwin/patched/results.json
<EVIDENCE_ROOT>/darwin/diagnostics/results.json
<EVIDENCE_ROOT>/linux/runner-preflight.json
<EVIDENCE_ROOT>/linux/baseline/contracts.json
<EVIDENCE_ROOT>/linux/baseline/contracts.sha256
<EVIDENCE_ROOT>/linux/patched/results.json
<EVIDENCE_ROOT>/validation-report.md
```

#### Immutable manifest and interface hashes

`manifest.json` is canonical UTF-8 JSON: object keys lexicographically sorted, array order preserved, insignificant whitespace removed, one trailing LF. It records at minimum:

- `schemaVersion`, `manifestId`, positive `generation`, `createdAtUtc`, exact `baselineCommit`.
- platform OS/kernel/architecture and toolchain paths/versions for `CC`, linker, `NM`, `OTOOL`, and `FILE`.
- `interfaces.driverPath`, `driverSha256`, `fixtureInterfaceVersion`, `fixtureDefinitionsSha256`, `assertionInterfaceVersion`, `assertionDefinitionsSha256`, and `manifestSchemaSha256`.
- each fixed record's `fixtureId`, `operationKind`, frozen input values/digests, input files, ordered command argv, logical cwd role, environment allowlist, ordered effective ld arguments, preconditions, result classification, rejected options, artifact state, diagnostic digest, counterexample, and `C_F`.

Freeze writes temporary files, validates schema/hash/required fixture IDs/record order/three-category non-emptiness/expected `C_F` values, then atomically renames. It refuses a non-empty baseline evidence directory and never overwrites a manifest. Verification recalculates the sidecar and all embedded hashes before any fixture runs; empty `B_M`, missing fixture/category/field, changed input, baseline mismatch, interface mismatch, or hash mismatch fails the whole mode without partial execution.

## Task Dependency Graph

```text
1 [standalone driver complete + pristine Darwin baseline freeze]
├── 2 [GNU/Linux preservation baseline branch; may become BLOCKED]
│   └──────────────────────────────────────────────┐
└── 3.1 [DARWIN_BUILD canonical conditional]       │
    ├── 3.2 [runtime rpath] ───────────────────┐   │
    ├── 3.3 [Darwin reference object] ─────────┼───┤
    └── 3.4 [Darwin retention flag] ───────────┘   │
                       │                            │
                       └── 3.5 [exact generation] ─┼─────────────┐
                              ├── 3.6 [Darwin Property 1]        │
                              │   └── 3.7 [Darwin diagnostics +  │
                              │             actual/reproduction]│
                              ├── 3.8 [Linux Property 2] ◄───────┘ from task 2
                              └── 3.9 [generation/scope audit]

4 [final checkpoint] ◄── 3.7 + 3.8 + 3.9
```

Task 2/3.8のLinux branchがblockedでも、3.1〜3.7の製品修正とDarwin evidence、および3.9のgeneration/scope evidenceを継続する。Task 4だけが全required branchを要求する。

```json
{
  "waves": [
    {
      "wave": 1,
      "tasks": ["1"],
      "dependsOn": [],
      "execution": "sequential"
    },
    {
      "wave": 2,
      "tasks": ["2", "3.1"],
      "dependsOn": ["1"],
      "execution": "parallel-independent-branches",
      "blockedBehavior": "task 2 may be BLOCKED without blocking task 3.1"
    },
    {
      "wave": 3,
      "tasks": ["3.2", "3.3", "3.4"],
      "dependsOn": ["3.1"],
      "execution": "parallel"
    },
    {
      "wave": 4,
      "tasks": ["3.5"],
      "dependsOn": ["3.2", "3.3", "3.4"],
      "execution": "sequential"
    },
    {
      "wave": 5,
      "tasks": ["3.6", "3.8", "3.9"],
      "dependsOn": {
        "3.6": ["3.5"],
        "3.8": ["2", "3.5"],
        "3.9": ["3.5"]
      },
      "execution": "parallel-independent-branches",
      "blockedBehavior": "blocked task 3.8 does not block tasks 3.6 or 3.9"
    },
    {
      "wave": 6,
      "tasks": ["3.7"],
      "dependsOn": ["3.6"],
      "execution": "sequential"
    },
    {
      "wave": 7,
      "tasks": ["4"],
      "dependsOn": ["3.7", "3.8", "3.9"],
      "execution": "sequential",
      "blockedBehavior": "any required blocked branch makes final completion BLOCKED"
    }
  ]
}
```

## Tasks

- [x] 1. Complete and freeze the standalone driver, then capture the Darwin bug baseline
  - **Property 1: Bug Condition** - Frozen Apple ld64 Inputs Satisfy Artifact Contracts
  - **CRITICAL**: product/build-ruleの変更前に `testsuite/macos_build_compatibility.sh` 1本へ、全5 mode、上記fixed fixture、`baselineBugCondition`、`expectedBehavior`、Linux observable-contract comparison、aggregate diagnostics、manifest canonicalization/hash、CLI/env/status validationを実装する。
  - driverを`testsuite/Makefile.am`へ登録しない。helper、second driver、custom harness/logger、PBT dependencyを追加しない。
  - RuntimeRpathではunfixed `-Wl,-rpath=P`がeffective ld argument `-rpath=P`となること、EmbeddedReferenceでは`-z noexecstack`と`--format=binary`、DependencyRetentionでは`--no-as-needed`がApple ld64へ到達することをordered effective argumentsから判定する。
  - bug classificationはDarwin/arm64、Apple Clang/ld64、operation到達、前提成功、対象unsupported option rejectionによるnonzero、artifact absent/unchangedをすべて要求する。compile failure、missing input、unrelated linker failureを`C_F`へ含めない。
  - missing-input fixtureを`not_reached`かつ`C_F=false`として記録し、7 bug fixturesが`C_F=true`、3 categoryが非空であることをhard gateにする。
  - Property 1 expected-behavior assertionはunfixed 7 fixtureでFAILして具体的counterexampleをsurfaceする。freeze mode自体は、その期待されたfailureを全件観測しvalid immutable manifestをatomic publishできた場合だけstatus 0を返す。
  - pristine baseline commit、clean source snapshot、空のexternal evidence directoryをpreflightし、次を実行する（tool pathとtripletは実環境のabsolute valueへ置換する）。

    ```sh
    HOST=<DARWIN_TRIPLET> PATH=<PINNED_PATH> \
    CC=<ABS_APPLE_CLANG> LD=<ABS_APPLE_LD> NM=<ABS_NM> \
    OTOOL=<ABS_OTOOL> FILE=<ABS_FILE> LC_ALL=C TZ=UTC \
    testsuite/macos_build_compatibility.sh \
      --mode freeze-darwin-baseline \
      --source-tree <ABS_PRISTINE_BASELINE_TREE> \
      --build-root <ABS_DARWIN_BASELINE_BUILD_ROOT> \
      --evidence-dir <ABS_EVIDENCE_ROOT>
    ```

  - `manifest.json`/sidecarを再読込し、baseline commit、record order、fixed inputs/hashes、effective arguments、counterexamples、interface hashes、`B_M` non-emptiness、3 category coverageを確認する。
  - baseline取得後はdriver/interfaceを凍結する。変更が必要ならmanifestを再利用せず、旧generationをexternal evidence内でread-only archiveし、product rule未修正のpristine baselineから全8 recordsを新しいmanifest ID/incremented generationで再取得する。
  - **EXPECTED OUTCOME**: expected-behavior propertyはunfixed fixturesでFAILし、freeze commandは3 categoryのcounterexampleをvalid immutable manifestへ凍結して0を返す。
  - **完了条件**: driverの全ロジックが実装済み、manifest/interfaceが凍結済み、product/build-rule変更が0行である。以後のdriver taskは環境配線、実行、evidence確認だけであり、新規logicを追加しない。
  - _依存: なし_
  - _並行実行: 不可。全製品修正およびLinux captureより先に完了する_
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7_

- [x] 2. Capture the GNU/Linux preservation baseline on a preflighted runner
  - **Property 2: Preservation** - GNU/Linux Build Artifacts Remain Equivalent
  - **IMPORTANT**: observation-first methodologyで、patched resultを見る前にpristine unfixed baselineのobservable contractsを取得する。driver logic、fixture、oracle meaningはtask 1の凍結後に変更しない。
  - Linux VM、container、またはremote runnerで`uname -s == Linux`を確認し、runner identity/image digest、architecture、kernel、distribution、compiler/linker/binutils/make/shell/Autotools/tool pathsとversionsを`linux/runner-preflight.json`へ記録する。
  - commit `a44a5b8cd1704890c183b7dc44984ab1c2e7a519`のobjectを検証し、そのcommitからunexpected tracked/untracked changesのないpristine baseline snapshotを作る。source、build、evidenceを分離し、baseline build rootをpatched build rootと共有しない。
  - compiler cacheをdisableするか同じempty-cache policyを定義し、`PATH`, `CC`, `LD`, `AR`, `AS`, `NM`, `OBJCOPY`, `READELF`, `MAKE`, shell, locale, timezone, umask, dependency versions、ordered configure argvを固定・記録する。
  - task 1のdriver/fixture/assertion/schema hashesとformal Darwin manifestの値が一致しなければcaptureを開始しない。
  - RuntimeRpathのordered `RPATH`/`RUNPATH`、reference fixtureのsymbol名/linkage/payload/end-start/consumer-visible bytesとGNU ld/objcopy trace、retention fixtureのpre-link IDsとordered `DT_NEEDED`をbaseline contractとして保存する。binary全体のhash、timestamp、UUID、tool metadataをequivalence oracleにしない。
  - 次を同じrunner contractで実行する。

    ```sh
    HOST=<LINUX_TRIPLET> PATH=<PINNED_PATH> \
    CC=<ABS_CC> LD=<ABS_LD> AR=<ABS_AR> AS=<ABS_AS> NM=<ABS_NM> \
    FILE=<ABS_FILE> READELF=<ABS_READELF> OBJCOPY=<ABS_OBJCOPY> \
    MAKE=<ABS_MAKE> LC_ALL=C TZ=UTC \
    testsuite/macos_build_compatibility.sh \
      --mode capture-linux-baseline \
      --source-tree <ABS_PRISTINE_LINUX_BASELINE_TREE> \
      --build-root <ABS_LINUX_BASELINE_BUILD_ROOT> \
      --evidence-dir <ABS_EVIDENCE_ROOT>
    ```

  - `contracts.json`とsidecarを再検証し、全preservation fixtures、runner/config/environment/fixture hashes、ordered configure argv、observable contractsが存在することを確認する。
  - runnerがない場合はtask 2/3.8 branchを`BLOCKED_LINUX_RUNNER_UNAVAILABLE`として記録し、task 3.1以降のDarwin/product workを継続する。status 77、not reached、PASSとして扱わない。
  - **EXPECTED OUTCOME**: Property 2 baseline assertionsがunfixed GNU/Linux codeでPASSし、immutable comparison oracleがpatch外evidenceへ保存される。runnerなしなら明示的BLOCKEDとなる。
  - _依存: task 1_
  - _並行実行: task 3.1と独立に実行可。blockedでもDarwin branchを止めない_
  - _Requirements: 3.1, 3.2, 3.3, 3.4_

- [x] 3. Fix the three Apple ld64 build-operation incompatibilities and validate each branch
  - **必須範囲**: product changes are limited to portable rpath spelling, Darwin reference-object generation, Darwin omission of the GNU retention flag, and the single shared conditional/generated configure hunk needed to select those rules. Driver changes after task 1 are prohibited unless the entire pristine Darwin baseline is reacquired first.
  - _依存: task 1. Task 2 is not a prerequisite for Darwin implementation/evidence_

  - [x] 3.1 Add the shared Darwin build conditional to canonical configuration
    - `configure.ac`で既存の`case "$host" in *darwin*)` styleを再利用し、Darwinだけtrueになる`DARWIN_BUILD` Automake conditionalを1つ追加する。
    - `!LINUX_BUILD`、`!WITH_GNU_LD`、別の`host_os`判定、runtime `#ifdef`、compatibility shimを追加しない。
    - このtaskではgenerated `configure`/`Makefile.in`を手編集・同期しない。
    - _Bug_Condition: `baselineBugCondition(X, F(X))`のEmbeddedReference/DependencyRetention cases where Darwin routes GNU-only options to Apple ld64_
    - _Expected_Behavior: select the Darwin build rules that satisfy `expectedBehavior(X, F'(X))`_
    - _Preservation: keep every non-Darwin host on the existing GNU path_
    - _依存: task 1_
    - _並行実行: task 2と独立。3.2〜3.4より先に完了する_
    - _Requirements: 2.2, 2.3, 2.8, 3.5, 3.6, 3.7, 3.8_

  - [x] 3.2 Replace only the runtime-rpath equals form
    - `auxdir/slurm.m4`の`X_AC_LIBSLURM`で`-Wl,-rpath=$libdir/slurm`を`-Wl,-rpath,$libdir/slurm`へ変更する。
    - `-L$(top_builddir)/src/api/.libs -lslurmfull`、`-export-dynamic`、path interpretation、supported path domainを変更せず、OS分岐や特殊path supportを追加しない。
    - _Bug_Condition: RuntimeRpath X where supported non-empty P becomes one Apple ld64 argument `-rpath=P` and is rejected_
    - _Expected_Behavior: zero status, Mach-O artifact, no `-rpath=` argument, and exact `LC_RPATH == P`_
    - _Preservation: GNU/Linux ordered runtime-path entries equal the frozen baseline contract_
    - _依存: task 3.1_
    - _並行実行: 3.3、3.4と並行可_
    - _Requirements: 2.1, 2.5, 2.7, 3.1, 3.6_

  - [x] 3.3 Add only the Darwin `.incbin` reference-object branch
    - `make_ref.include`の`%.bino: %.txt`だけを`DARWIN_BUILD`で分岐する。non-Darwin branchのexisting GNU ld `-z noexecstack --format=binary` and objcopy section-rename pathは意味上変更しない。
    - Darwin branchはquoted `cd "$(abs_srcdir)"`、safe basename validation `[A-Za-z0-9_.-]+`、non-alphanumeric/underscore-to-underscore symbol normalization、fixed-format `printf '%s\n'`を使用する。
    - `.section __TEXT,__const`、Darwin C ABI decorated start/end globals、`.incbin "<safe-basename>"`を`$(CC) -x assembler -c -o "$(abs_builddir)/$*.bino" -`へ渡す。source-root absolute pathや中間`.s`を作らない。
    - start/payload/end間へpadding、NUL、alignment、metadataを挿入せず、C/CPP flagsをassemblerへ渡さない。`_size` symbol、consumer、`src/common/ref.h`、`.bino`/`lib_ref.lo`/`lib_ref.la` graph、clean targetsを変更しない。
    - _Bug_Condition: EmbeddedReference X where readable payload reaches Apple ld64 with `-z noexecstack` and `--format=binary`_
    - _Expected_Behavior: Mach-O relocatable consumer target, exact decorated boundaries, `end-start == N`, exact bytes, and consumer link without boundary-symbol undefineds_
    - _Preservation: non-Darwin GNU command path, symbols, payload, linkage, and consumer-visible output equal baseline_
    - _依存: task 3.1_
    - _並行実行: 3.2、3.4と並行可_
    - _Requirements: 2.2, 2.5, 2.6, 2.7, 3.2, 3.3, 3.6_

  - [x] 3.4 Make `--no-as-needed` non-Darwin-only
    - `src/slurmd/slurmd/Makefile.am`で`depend_ldflags += -Wl,--no-as-needed`を`if !DARWIN_BUILD`内へ置く。
    - Darwin代替flagを追加せず、`depend_ldadd`、`slurmd_LDADD`、`slurmd_LDFLAGS`、operand/library orderを変更しない。
    - Dはaffected strong dylib operandsのinstall namesからlink前に決定する。framework、weak/reexport dylib、archive、object、transitive-only dependencyを通常strong dylibへ一般化しない。
    - _Bug_Condition: DependencyRetention X where successful compilation is followed by Apple ld64 rejection of `--no-as-needed`_
    - _Expected_Behavior: zero status, no `--no-as-needed`/unexpected `-dead_strip_dylibs`, and pre-link D included in strong direct load dependencies_
    - _Preservation: GNU/Linux retains `--no-as-needed` and the baseline ordered direct dependencies_
    - _依存: task 3.1_
    - _並行実行: 3.2、3.3と並行可_
    - _Requirements: 2.3, 2.5, 2.7, 3.4, 3.6_

  - [x] 3.5 Generate and retain only the intended `configure` output
    - candidate canonical patchを適用したclean disposable treeを用意し、source/build/evidenceを分離する。candidate working treeをtrial-and-error generator environmentにしない。
    - exact preflight commandsを実行し、各first lineがAutoconf/autoreconf `2.72`、Automake/aclocal `1.18.1`でなければ`BLOCKED_GENERATOR_VERSION_MISMATCH`とする。

      ```sh
      autoconf --version
      autoreconf --version
      automake --version
      aclocal --version
      ```

    - tool pathを固定した同一`PATH`を使い、network/package installationなしでrepository top-levelからpass 1を実行する。実行前のcanonical inputs、tracked generated outputs、git diff/hashをexternal evidenceへ保存する。

      ```sh
      env LC_ALL=C TZ=UTC autoreconf --force
      ```

    - pass 1直後の同じworktreeをrestore、checkout、reset、clean、copyし直さず、そのまま同一commandでpass 2を実行する。
    - pass 1/2のtracked diffとbyte hashesを比較し、pass 2追加差分、canonical input変更、pass間のgenerated byte差、allowlist外generated changeがあればfailする。
    - branch expansion evidenceを保存してから全`Makefile.in`差分をdiscardする。`aclocal.m4`、`config.h.in`、auxiliary scripts等の差分はrejectする。
    - `configure.ac`/`auxdir/slurm.m4`へ直接対応する意図した`configure` hunkだけをverified disposable treeからcandidateへ移し、content hash一致を確認する。generated fileを手編集しない。
    - _Bug_Condition: canonical/generated drift prevents the corrected operations from being selected_
    - _Expected_Behavior: exact generators reproducibly emit the intended conditional/rpath configure changes_
    - _Preservation: no canonical drift and no submitted `Makefile.in` or unrelated generated output_
    - _依存: tasks 3.2, 3.3, 3.4_
    - _並行実行: 不可_
    - _Requirements: 2.5, 3.5, 3.6_

  - [x] 3.6 Re-run the frozen Darwin property against the patched operations
    - **Property 1: Expected Behavior** - Frozen Apple ld64 Inputs Satisfy Artifact Contracts
    - **IMPORTANT**: task 1の同じdriver、manifest、B_M、fixtures、assertionsを使用する。新規driver logic/fixture/expected valueを追加せず、`F'(X)`へ`baselineBugCondition`または同等のbug-condition predicateを再評価しない。
    - 実行前にmanifest sidecar、embedded interface hashes、baseline commit、fixed IDs/order、record completeness、3-category non-emptinessを再検証する。empty B_M、fixture/category欠落、input/interface/hash mismatchはfixtureを実行せずmode全体をfailする。
    - frozen `X`ごとに`expectedBehavior(X, F'(X))`を適用し、rpath exact value、reference target/symbol/boundary/bytes/consumer link、pre-link D subsetを検査する。
    - task 1で凍結したdriverへの変更が見つかった場合、patched evidenceを作らずtask 1のbaseline reacquisition ruleへ戻る。

      ```sh
      HOST=<DARWIN_TRIPLET> PATH=<PINNED_PATH> \
      CC=<ABS_APPLE_CLANG> LD=<ABS_APPLE_LD> NM=<ABS_NM> \
      OTOOL=<ABS_OTOOL> FILE=<ABS_FILE> LC_ALL=C TZ=UTC \
      testsuite/macos_build_compatibility.sh \
        --mode verify-darwin-fix \
        --source-tree <ABS_PATCHED_TREE> \
        --build-root <ABS_DARWIN_PATCHED_BUILD_ROOT> \
        --evidence-dir <ABS_EVIDENCE_ROOT> \
        --manifest <ABS_EVIDENCE_ROOT>/darwin/baseline/manifest.json
      ```

    - `darwin/patched/results.json`で全7 bug fixturesがexecuted/PASS、missing-input classificationが期待どおり、forbidden argumentとartifact violationが0件であることを確認する。
    - **EXPECTED OUTCOME**: task 1でexpected behaviorを満たさなかった同じfrozen XがすべてPASSする。
    - _依存: task 3.5_
    - _並行実行: 3.8、3.9と独立に実行可_
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.6, 2.7, 2.8_

  - [x] 3.7 Verify aggregate diagnostics and actual rules or equivalent reproductions
    - task 1で凍結したmulti-violation injection semanticsを使い、全affected operation names、全forbidden options、全unmet artifact contractsを蓄積してraw verificationがnonzeroとなること、およびmeta-checkが期待した全診断を観測して0を返すことを確認する。driver logicを変更しない。

      ```sh
      HOST=<DARWIN_TRIPLET> PATH=<PINNED_PATH> \
      CC=<ABS_APPLE_CLANG> LD=<ABS_APPLE_LD> NM=<ABS_NM> \
      OTOOL=<ABS_OTOOL> FILE=<ABS_FILE> LC_ALL=C TZ=UTC \
      testsuite/macos_build_compatibility.sh \
        --mode verify-aggregate-diagnostics \
        --source-tree <ABS_PATCHED_TREE> \
        --build-root <ABS_DARWIN_DIAGNOSTICS_BUILD_ROOT> \
        --evidence-dir <ABS_EVIDENCE_ROOT> \
        --manifest <ABS_EVIDENCE_ROOT>/darwin/baseline/manifest.json
      ```

    - out-of-tree Darwin validationでactual generated rpath rule、reference graph `.txt -> .bino -> lib_ref.la -> consumer`、slurmd retention linkを個別に試行し、operation到達性とeffective argumentsを記録する。
    - 周辺failureでinvocation前に停止したoperationは`not reached: <specific reason>`とし、同じtoolchain、input bytes/values、effective arguments、artifact typeを保つlimited reproductionを必ず実行する。filesystem locationとunrelated surrounding stepsだけを変更可能とする。
    - actual/reproductionの各operationがProperty 1 artifact contractを満たすことを確認し、full buildやruntime executionを要求しない。
    - validation reportへ、macOSはunsupportedであり3 build operationsだけを検証し、clients/daemons/plugins/job execution/runtime behavior/dyld state inheritanceを検証しない旨を記録する。このreportはexternal evidenceにのみ置く。
    - _依存: task 3.6_
    - _並行実行: 不可_
    - _Requirements: 1.4, 2.4, 2.5, 2.7, 2.8, 3.9, 3.10_

  - [x] 3.8 Verify GNU/Linux preservation with pristine matched snapshots
    - **Property 2: Preservation** - GNU/Linux Build Artifacts Remain Equivalent
    - task 2と同じrunner instance/imageでbaseline commit objectを再確認し、同じbaseline commitへcandidate patchを適用したpristine patched snapshotを別pathへ作る。baseline/patched双方のtracked stateとunexpected untracked filesを検査する。
    - baseline/patchedでcompiler/linker/binutils/make/shell/Autotools/dependency identities、ordered configure argv、`PATH`, `CC`, `LD`, `AR`, `AS`, `NM`, `OBJCOPY`, `READELF`, `MAKE`, locale, timezone, umask、cache policy、fixture/interface hashesが同一であることをpreflightする。
    - baselineとpatchedは別build rootsを使用し、evidenceは両source/build/git worktree外へ置く。runnerへsource、fixture、candidate patch以外の秘密情報を送らない。
    - task 2の`contracts.json`と同じfixtures/assertionsを使い、ordered RPATH/RUNPATH、reference symbols/linkage/payload/consumer output、ordered `DT_NEEDED`を比較する。patched Linux reference traceがGNU ld/objcopy path、retention traceが`--no-as-needed`を維持することを確認する。

      ```sh
      HOST=<SAME_LINUX_TRIPLET> PATH=<SAME_PINNED_PATH> \
      CC=<SAME_ABS_CC> LD=<SAME_ABS_LD> AR=<SAME_ABS_AR> AS=<SAME_ABS_AS> \
      NM=<SAME_ABS_NM> FILE=<SAME_ABS_FILE> READELF=<SAME_ABS_READELF> \
      OBJCOPY=<SAME_ABS_OBJCOPY> MAKE=<SAME_ABS_MAKE> LC_ALL=C TZ=UTC \
      testsuite/macos_build_compatibility.sh \
        --mode verify-linux-preservation \
        --source-tree <ABS_PRISTINE_LINUX_PATCHED_TREE> \
        --build-root <ABS_LINUX_PATCHED_BUILD_ROOT> \
        --evidence-dir <ABS_EVIDENCE_ROOT> \
        --baseline-contract <ABS_EVIDENCE_ROOT>/linux/baseline/contracts.json
      ```

    - runner unavailable/preflight mismatch/task 2未完了ならこのbranchを理由付き`BLOCKED`とし、Darwin task 3.6/3.7とscope task 3.9を継続する。oracle更新、status 77、not reached、Darwin resultによる代用を禁止する。
    - **EXPECTED OUTCOME**: task 2のsame Property 2がpatched GNU/Linux snapshotでもPASSする。
    - _依存: tasks 2, 3.5_
    - _並行実行: 3.6、3.9と独立に実行可_
    - _Requirements: 3.1, 3.2, 3.3, 3.4_

  - [x] 3.9 Audit generation evidence, candidate patch scope, and untracked files
    - task 3.5のexact-version preflight、same-tree restore-free pass 1/2 commands、hash/diff equality、discarded `Makefile.in` evidence、retained `configure` hashをexternal evidenceから再検証する。
    - baseline commitに対するtracked diffをpath/hunk単位でauditし、candidate patch allowlistを次の6 pathsだけに固定する。

      ```text
      configure.ac
      auxdir/slurm.m4
      make_ref.include
      src/slurmd/slurmd/Makefile.am
      configure
      testsuite/macos_build_compatibility.sh
      ```

    - allowlist path内でも、shared conditional、3 corrected operations、direct generated configure hunk、single driver以外のhunkをrejectする。
    - `git status --porcelain --untracked-files=all`相当でuntracked filesを全列挙し、driver以外のuntracked source/test fileをrejectする。tracked diffだけのauditで完了しない。
    - `testsuite/Makefile.am`、全`Makefile.in`、`.kiro/**`、manifest/evidence、`validation-report.md`がcandidate patch/staging/exportに含まれないことを確認する。evidence/reportがsource tree内にあればignoreせずblockedにする。
    - plugin loader/interface/runtime state、compatibility shim、platform APIs、security/credential/privilege/authentication、protocol、public API/ABI、command options、configuration interpretationの変更が0行であることを確認する。
    - _依存: task 3.5_
    - _並行実行: 3.6、3.8と独立に実行可_
    - _Requirements: 2.8, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10_

- [x] 4. Checkpoint - Require Darwin, Linux, and generation/scope evidence
  - Darwin branchでimmutable manifest、same frozen XのProperty 1 PASS、aggregate diagnostics PASS、全3 operationのactual executionまたは理由付きnot reached + equivalent limited reproduction PASSが揃うことを確認する。
  - Linux branchでrunner preflight、pristine matched snapshots、baseline contract、Property 2 PASSが揃うことを確認する。runner不在またはpreflight failureならDarwin PASSを保持したまま全体statusを`BLOCKED`とし、completionとしない。
  - generation/scope branchでexact generator versions、same-tree pass 1/2 idempotence、intended configure-only generated diff、6-path tracked hunk allowlist、untracked audit、candidate外evidence/report、scope exclusionがPASSすることを確認する。
  - `<EVIDENCE_ROOT>/validation-report.md`から各requirement IDをevidence recordへtraceし、unsupported macOS disclaimerとoperation別executed/not-reached classificationを確認する。
  - full macOS build、runtime execution、またはpost-submission CIをlocal completion判定へ追加しない。未実行のfull local Linux CIをPASSと表現しない。
  - 質問または対象内failureが残る場合だけユーザーへ確認する。
  - _依存: tasks 3.7, 3.8, 3.9_
  - _並行実行: 不可。3 branchの最終合流点_
  - _Requirements: 1.1, 1.2, 1.3, 1.4, 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 2.8, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6, 3.7, 3.8, 3.9, 3.10_

## Requirement Traceability

| Requirement | Primary task(s) | Required evidence |
|---|---|---|
| 1.1 | 1, 4 | Frozen unfixed `-rpath=P` rejection counterexamples |
| 1.2 | 1, 4 | Frozen unfixed GNU binary-link option rejection counterexamples |
| 1.3 | 1, 4 | Frozen unfixed `--no-as-needed` rejection counterexamples |
| 1.4 | 1, 3.7, 4 | Explicit standalone invocations; no testsuite registration |
| 2.1 | 1, 3.2, 3.6, 4 | Same frozen X, no equals form, exact `LC_RPATH` |
| 2.2 | 1, 3.1, 3.3, 3.6, 4 | GNU-only options absent and Mach-O reference object |
| 2.3 | 1, 3.1, 3.4, 3.6, 4 | No GNU retention flag and pre-link D included |
| 2.4 | 1, 3.7, 4 | Multi-violation aggregate diagnostic evidence |
| 2.5 | 1, 3.2, 3.3, 3.4, 3.6, 3.7, 4 | Non-empty three-category frozen set and corrected operations |
| 2.6 | 1, 3.3, 3.6, 4 | Exact symbols, boundaries, bytes, target, consumer link |
| 2.7 | 1, 3.6, 3.7, 4 | Actual-rule or equivalent limited-reproduction records |
| 2.8 | 3.1, 3.6, 3.7, 3.9, 4 | Acceptance restricted to three build operations |
| 3.1 | 2, 3.2, 3.8, 4 | Matched-runner ordered runtime-path equivalence |
| 3.2 | 2, 3.3, 3.8, 4 | Matched-runner symbol/linkage/payload equivalence |
| 3.3 | 2, 3.3, 3.8, 4 | Matched-runner consumer-visible output equivalence |
| 3.4 | 2, 3.4, 3.8, 4 | GNU flag and ordered direct-dependency equivalence |
| 3.5 | 3.1, 3.5, 3.9, 4 | Exact-version same-tree two-pass generation |
| 3.6 | 3.2, 3.3, 3.4, 3.5, 3.9, 4 | Six-path tracked hunk and untracked-file audit |
| 3.7 | 3.9, 4 | Zero plugin/interface/runtime-state changes |
| 3.8 | 3.9, 4 | Zero security/protocol/API/ABI changes |
| 3.9 | 3.7, 3.9, 4 | Patch-external unsupported macOS report |
| 3.10 | 3.7, 3.9, 4 | Blocker separation and limited-reproduction acceptance |

## Post-submission follow-up

コミュニティ提出後にupstream Linux CI結果を確認し、failureがcandidate patchに関連する場合は分類・修正・再検証する。このfollow-upはsubmission前には実行不能なため、上記implementation dependency graph、task completion、local final checkpointのdependencyまたはgateには含めない。
