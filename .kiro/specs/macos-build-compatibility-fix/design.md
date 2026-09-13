# macOS Build Compatibility Fix Bugfix Design

## Overview

本設計は `bugfix.md` を唯一の受け入れ基準として、対象baseline commit `a44a5b8cd1704890c183b7dc44984ab1c2e7a519` で実証された次の3つのApple Clang/Apple ld64 build operationだけを修正する。

1. `auxdir/slurm.m4` が生成するruntime search path引数
2. `make_ref.include` によるreference-textのrelocatable object化
3. `src/slurmd/slurmd/Makefile.am` のdependency-retention link flag

製品build ruleの変更方針は次の3点に限定する。

- runtime search pathは、GNU ldとApple ld64の双方が受理するcompiler-driver表現 `-Wl,-rpath,<P>` に統一する。
- reference textは、DarwinだけApple Clang integrated assemblerの `.incbin` を使って `__TEXT,__const` を持つMach-O objectを生成する。非Darwinでは既存GNU ld/objcopy経路を維持する。
- dependency retentionは、DarwinではGNU ld固有の `--no-as-needed` を渡さず、明示されたstrong dylibをdirect load dependencyとして保持するld64既定動作を利用する。非Darwinでは既存flagを維持する。

Fix checkingの空集合によるvacuous passを禁止するため、修正前関数・build operation `F` の実行結果からbaseline predicate `C_F(X)` を評価し、bugを再現したfixture input `X`、effective arguments、failure cause、counterexampleをimmutable baseline manifestへ凍結する。修正後 `F'` の検証ではbug conditionを再評価しない。同じ凍結input集合へ `expectedBehavior(X, F'(X))` を適用し、manifestが不正、空、または3 operation categoryのいずれかを欠く場合は検証自体を失敗させる。

回帰検証は、既存testsuite直下へ新しいroot harnessを構築せず、単一standalone aggregate driver `testsuite/macos_build_compatibility.sh` を明示的に独立実行する。`testsuite/Makefile.am` には `TESTS`、`TEST_EXTENSIONS`、`LOG_COMPILER`、`AM_TESTS_ENVIRONMENT` が存在しないため、suite登録を本bugfixの前提または完了条件にしない。要件1.4のcoverage gapは、standalone driverの規定コマンドを必須evidenceとして実行することで埋める。

検証は次の2 branchを独立に進め、最終completion gateでのみ合流させる。

- **Darwin Fix Evidence Branch**: pristine baselineでmanifestを凍結し、同じinputをpatched operationへ適用してProperty 1を検証する。
- **GNU/Linux Preservation Evidence Branch**: Linux VM、container、またはremote runner上でpristine baselineとpatched snapshotを同一toolchain/configuration/environment/fixturesで比較し、Property 2を検証する。

Linux runner不足はDarwin evidenceの作成を妨げない。ただしLinux preservationはrequired gateであり、runnerが利用できない場合の全体completion statusは `BLOCKED` とする。これは `not reached`、skip、またはpassではない。post-submission upstream CI確認は実装完了後のfollow-upであり、本設計の実装依存グラフおよびlocal completion gateには含めない。

runtime code、plugin loader、compatibility shim、security/authentication、protocol/API/ABI、daemon runtime、GPU、cgroup、process tracking、job accounting、UID/GID切替、または長期macOS portの課題には触れない。full macOS build、client/daemon/plugin/job execution、dyld runtime-state inheritanceは成功条件にしない。

### Repository and Toolchain Evidence

対象commitのローカルソースとApple Clang 21.0.0 / Apple ld64 build 1267上の限定実験では、次を確認済みである。

- supported path domain内の `-Wl,-rpath,/tmp/kiro-rpath` はlinkに成功し、完全一致する `LC_RPATH` を生成する。
- `.section __TEXT,__const`、global start/end labels、`.incbin` を含むassembler inputはrelocatable Mach-O objectになり、既存と同型のC consumerがlinkおよびpayload比較に成功する。
- 使用symbolのないfixture dylibを明示的にlinkしても、`-dead_strip_dylibs` を指定しないld64既定動作では `LC_LOAD_DYLIB` が保持される。
- `ld -r -sectcreate` 単独ではobject input不足となり、既存consumer名のstart/end symbolも直接提供しない。
- 現行 `configure.ac` には `AM_PROG_AS` がなく、生成済みMakefileにも `CCAS`/`CCASFLAGS` の定義・使用がない。そのためDarwin reference ruleはconfigured `CC` のnative targetとprocess environmentを使用し、C専用flagsをassemblerへ渡さない。

これらは設計実現性の証拠であり、immutable baseline manifestおよび実装後evidenceの代替ではない。

## Glossary

- **Bug_Condition (`C_F`)**: unfixed baseline operation `F(X)` の結果について、対象GNU optionがApple ld64へ到達し、その拒否が非zero resultの原因になったことを示すpredicate。`F'` の結果には再評価しない
- **Property (`P(result)`)**: frozen bug inputをfixed operationへ与えた結果が、zero status、禁止option不在、およびoperation固有artifact contractを満たすこと
- **Preservation**: target-baseline GNU/Linux operationとfixed operationが、同一runner契約のもとで同じobservable artifact contractを生成すること
- **F**: commit `a44a5b8cd1704890c183b7dc44984ab1c2e7a519` のunfixed build ruleまたはlimited reproduction
- **F'**: fixed build ruleまたは同値limited reproduction
- **Frozen Bug Input Set (`B_M`)**: valid immutable baseline manifest `M` で `C_F(X) == true` と記録されたinput `X` の集合
- **Immutable Baseline Manifest (`M`)**: fixture ID、input、input hash、toolchain、effective arguments、failure cause、counterexample、driver/assertion/fixture interface hashをcanonical JSONとして凍結したDarwin baseline evidence
- **Interface Hash**: standalone driver bytes、fixture definition、assertion semantics、manifest schemaの各SHA-256。baseline取得後のtest meaning変更を検出する
- **Evidence Root**: userが `--evidence-dir` で指定するabsolute directory。source tree、build tree、git worktreeの外側でなければならない
- **Linux Runner**: Linux VM、container、またはremote execution host。新しいrepository dependencyやSlurm固有runner実装ではなく、既存の利用可能な実行環境を指す
- **P (path value)**: 既存Slurm Autotools/Make/compiler-driver pipelineが単一valueとして扱えるsupported path domainに属する非空runtime path。通常のabsolute/nested pathと英数字、`/`、`.`、`_`、`-`等を含み、comma、ASCII whitespace、shell quoting/control semanticsを必要とするpathは含まない
- **S / N**: embedded-reference operationへ与える非空payload byte sequence、およびそのbyte length
- **Affected retention operands**: 対象slurmd link operationでdependency retentionのため明示される、原則 `depend_ldadd` 由来の通常strong dylib operands
- **D**: link前にaffected retention operandsを解決し、各input dylibの `LC_ID_DYLIB` から取得して凍結した期待install-name集合
- **Effective arguments**: compiler driverやlibtoolの展開後、最終的に対象linkerへ渡るargument列
- **Direct load dependency**: Mach-Oの通常strong `LC_LOAD_DYLIB` に記録された直接依存
- **Mach-O symbol decoration**: Darwin C ABIがC external symbolへleading underscoreを追加する規則。C identifier `_binary_usage_txt_start` は `nm` 上で `__binary_usage_txt_start` になる
- **Safe REF basename**: 現行 `REF` に列挙される、空でなく `[A-Za-z0-9_.-]+` に限定されたbasename。symbol生成時は英数字とunderscore以外をunderscoreへ正規化する
- **Limited reproduction**: filesystem locationと無関係な周辺build stepだけを省略し、toolchain、operation input、effective arguments、output artifact typeを対象ruleと同一にした独立検証
- **Canonical build input**: `configure.ac`、`auxdir/*.m4`、`Makefile.am`、およびincludeされる `make_ref.include`
- **Generated output**: Autoconf/Automakeがcanonical inputから生成する `configure` または `Makefile.in`
- **DARWIN_BUILD**: 既存 `case "$host" in *darwin*)` と同じhost分類でtrueになるAutomake conditional
- **not reached**: Darwin上で周辺portability failureまたは外部dependency不足により対象operation invocationまで到達しなかった状態。対象operationのpass/failとは別に記録する
- **blocked**: required verification infrastructureまたはpreconditionがなく、検証を実施できない状態。特にLinux runner不在は全体completionをblockedにし、status 77またはnot reachedへ変換しない

## Bug Details

### Bug Condition

bug conditionはunfixed baseline `F` の実行結果だけから定義する。`C_F(X)` は、Darwin/arm64、Apple Clang、Apple ld64でoperation固有の前提が成立し、対象GNU optionが実際にld64へ到達し、その拒否がnonzero resultの原因になった場合にtrueとなる。compile failure、missing input、外部dependency不足、または別のportability failureはfalseである。

**Formal Specification:**

```text
FUNCTION baselineBugCondition(input X, baselineResult R_F)
  INPUT: X of type BuildOperationInput
         R_F = F(X) of type BuildResult
  OUTPUT: boolean

  IF X.platform != Darwin/arm64
     OR X.compiler != AppleClang
     OR X.linker != AppleLd64
     OR R_F.invocationReached != true
     OR R_F.exitStatus == 0
     OR R_F.failureCause != RejectedUnsupportedOption THEN
    RETURN false
  END IF

  SWITCH X.kind
    CASE RuntimeRpath:
      RETURN R_F.compilationStagesSucceeded
             AND X.path != EMPTY
             AND X.path IN SUPPORTED_PATH_DOMAIN
             AND R_F.effectiveLdArgs CONTAINS SINGLE_ARG("-rpath=" + X.path)
             AND R_F.requestedArtifact IS absent_or_unchanged

    CASE EmbeddedReference:
      RETURN X.payloadExists
             AND X.payloadIsReadable
             AND R_F.effectiveLdArgs CONTAINS CONSECUTIVE_ARGS("-z", "noexecstack")
             AND R_F.effectiveLdArgs CONTAINS SINGLE_ARG("--format=binary")
             AND R_F.requestedArtifact IS absent_or_unchanged

    CASE DependencyRetention:
      RETURN R_F.compilationStagesSucceeded
             AND R_F.effectiveLdArgs CONTAINS SINGLE_ARG("--no-as-needed")
             AND R_F.requestedArtifact IS absent_or_unchanged

    OTHERWISE:
      RETURN false
  END SWITCH
END FUNCTION
```

`C_F` はbaseline manifest freeze時に一度だけ評価する。Fix checkingは次のように定義し、`F'(X)` へ `baselineBugCondition` または同等の `isBugCondition` を再評価してはならない。

```text
B_M := { X recorded in valid manifest M WHERE M.record[X].C_F == true }
ASSERT B_M IS NOT EMPTY
ASSERT B_M CONTAINS at_least_one RuntimeRpath input
ASSERT B_M CONTAINS at_least_one EmbeddedReference input
ASSERT B_M CONTAINS at_least_one DependencyRetention input

FOR EACH X IN B_M DO
  ASSERT expectedBehavior(X, F'(X))
END FOR
```

### Immutable Baseline Manifest Contract

#### Fixed fixture IDs

baseline manifestは次の固定fixture IDsを持つ。各bug fixtureは `C_F == true` でなければfreezeを失敗させる。

- `rpath-absolute`
- `rpath-nested`
- `reference-text`
- `reference-binary`
- `reference-multidot-certgen`
- `retention-one-dylib`
- `retention-two-dylib`

分類確認用 `classification-missing-input` は `C_F == false`、`invocationReached == false`、classification `not_reached` として別recordに保持するが、`B_M` には含めない。

#### Manifest schema

manifestはUTF-8 JSONで、少なくとも次を記録する。

```text
Manifest {
  schemaVersion: "1",
  manifestId: UUID,
  generation: positive_integer,
  createdAtUtc: informational_timestamp,
  baselineCommit: "a44a5b8cd1704890c183b7dc44984ab1c2e7a519",
  platform: { osVersion, kernelVersion, architecture },
  toolchain: {
    ccPath, ccVersion, linkerPath, linkerVersion,
    nmPath, otoolPath, filePath
  },
  interfaces: {
    driverPath: "testsuite/macos_build_compatibility.sh",
    driverSha256,
    fixtureInterfaceVersion,
    fixtureDefinitionsSha256,
    assertionInterfaceVersion,
    assertionDefinitionsSha256,
    manifestSchemaSha256
  },
  records: [
    {
      fixtureId,
      operationKind,
      input: {
        pathValue?, payloadLength?, payloadSha256?, payloadFileName?,
        preLinkD?, preLinkDSourceHashes?
      },
      inputFiles: [{ logicalName, size, sha256 }],
      command: { argv, cwdLogicalRole, environmentAllowlist },
      effectiveLdArgs,
      preconditions,
      result: {
        invocationReached, exitStatus, failureCause,
        rejectedOptionForms, artifactState, diagnosticDigest
      },
      counterexample,
      C_F
    }
  ]
}
```

`createdAtUtc` やabsolute evidence locationはprovenance情報であり、fixture identityやproperty oracleには使用しない。source/build rootの物理pathはlogical roleへ正規化し、filesystem locationの違いだけでlimited reproduction equivalenceを壊さない。

#### Freeze and hash rules

1. `freeze-darwin-baseline` はpristine baseline commit、clean worktree、空のbaseline evidence directoryでのみ実行する。既存manifestを上書きしない。
2. JSONはUTF-8、lexicographically sorted object keys、array order preserved、insignificant whitespaceなし、末尾LFありのcanonical formへserializeする。
3. canonical `manifest.json` 全体のSHA-256を計算し、同じdirectoryの `manifest.sha256` に lowercase hex とfilenameを記録する。
4. driver bytes、fixture definitions、assertion definitions、schema definitionは個別にSHA-256を計算し、manifest内へ埋め込む。
5. record arrayはfixed fixture ID orderで保存する。effective argument order、dependency order、input byte orderはsortしない。
6. freezeはtemporary fileへ完全出力し、schema、全hash、required fixture IDs、3 category non-emptiness、`C_F` 値を検証した後にatomic renameする。
7. verificationはsidecar hash、embedded interface hashes、baseline commit、fixture IDs、record completenessを再計算する。1つでも不一致なら検証違反としてnonzeroを返し、部分実行しない。
8. baseline manifestと全evidenceはEvidence Root配下へ置き、repositoryへcopy、stage、commitしない。

#### Baseline reacquisition rule

baseline freeze後にfixture input、fixture ID、assertion meaning、manifest schema、driver CLI/interface、effective-argument capture、failure classificationのいずれかを変更した場合、既存manifestを編集またはhash更新して再利用してはならない。変更後interfaceを使って、製品build rule未修正のpristine baseline commitから全fixtureのbaselineを再取得する。旧manifestはEvidence Root内でread-only archiveとして保持し、新manifestは新しい `manifestId`、incremented `generation`、再取得理由を持つ。新baselineでrequired fixtureの `C_F` がtrueにならない場合、root causeを再仮説化するまでfix checkingへ進まない。baseline commitを実行できない場合もfix checkingはblockedであり、patched resultからmanifestを合成してはならない。

### Examples

- **Runtime rpath**: `P=/opt/slurm/lib/slurm` のunfixed resultではld64へ単一argument `-rpath=/opt/slurm/lib/slurm` が渡され、artifactが生成されない。このinputとcounterexampleを `rpath-absolute` として凍結する。Fixed resultでは `-rpath` とPが別argumentsになり、Pと完全一致する `LC_RPATH` が必要である。
- **Nested runtime rpath**: `P=/opt/slurm/lib/slurm/plugins-v2` を `rpath-nested` として凍結する。comma、ASCII whitespace、shell control文字を含むpathはfixture domain外である。
- **Simple reference payload**: `usage.txt` が `usage\n` の6 bytesを含むとき、unfixed resultは `-z noexecstack --format=binary` の拒否を記録する。Fixed objectではC identifiers `_binary_usage_txt_start/end` がlink可能で、`end - start == 6`、全6 bytes一致が必要である。
- **Binary reference payload**: NUL、`0xff`、newlineを含むpayloadのexact bytesとSHA-256をmanifestへ凍結し、fixed `.incbin` objectで全offsetを比較する。
- **Multi-dot reference name**: `certgen.sh.txt` は `certgen_sh_txt` へ正規化され、Darwin objectは `__binary_certgen_sh_txt_start/end` をexportする。
- **Dependency retention**: fixture dylibへ既知install name `@rpath/libfixture-one.dylib` を設定し、そのinput IDからDをlink前に凍結する。Fixed resultでは追加retention flagなしで通常の `LC_LOAD_DYLIB` にDが含まれる必要がある。
- **Not reached**: payload fileが存在せずreference commandへ到達しないinputは `classification-missing-input` として記録するが、bug fixtureまたはProperty 1の母集団には数えない。

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**

- GNU/Linux runtime search pathは、supported path domain内のPについてbaselineと同じ順序・同じpath valuesで成果物へ記録される。
- GNU/Linux reference embeddingは、既存GNU ld `--format=binary` とobjcopy経路、start/end symbol名、linkage、payload bytes、consumer表示を維持する。
- GNU/Linux dependency-retention operationは `--no-as-needed` を引き続き使用し、baselineと同じdirect dependency identity/orderを維持する。
- `src/common/ref.h` とconsumer source、既存C identifier contractを変更しない。
- 既存 `.bino`、fake `lib_ref.lo`、`lib_ref.la` build graphとclean対象を維持する。
- public API/ABI、Slurm protocol、command option、configuration interpretation、runtime behaviorを変更しない。

**Scope:**

bug conditionに該当しない次の領域は非対象とする。

- GNU/Linuxおよび非Darwinの既存build path
- comma、ASCII whitespace、shell quoting/control semanticsを要する特殊runtime pathへの新規対応
- 対象operationに到達する前のcompile/configure/dependency failure
- plugin loading、dyld state、daemon起動、job execution、compatibility shim
- security/authentication、credential、cgroup、GPU、CPU affinity
- full macOS buildのその他のlinker/compiler error
- empty payloadの新しい意味定義
- CFLAGSだけでtargetを変更するDarwin cross/nondefault architecture、独自sysroot、独自deployment-target構成

### Generated File Preservation

再生成はcandidate source treeを直接試行錯誤に使わず、disposable pristine patched worktreeで実行する。preflightで次のexact commandsを実行し、first-line versionから `autoconf` と `autoreconf` が2.72、`automake` と `aclocal` が1.18.1であることを確認する。version不一致はblockedであり、別versionによる生成物を候補patchへ含めない。

```sh
autoconf --version
autoreconf --version
automake --version
aclocal --version
```

generator commandはrepository top-levelで実行する次の1 commandに固定する。tool pathを固定した `PATH` をpass 1/2で同一にし、network accessやpackage installationを再生成中に行わない。

```sh
env LC_ALL=C TZ=UTC autoreconf --force
```

実行手順は次のとおりである。

1. candidate patchを適用したclean disposable worktreeを作成し、canonical inputと全tracked generated filesのpre-generation hash/diffを保存する。
2. **Pass 1**: 上記generator commandを実行し、`configure`、全 `Makefile.in`、および他の変更されたgenerated filesのbyte hashとtracked diffをEvidence Rootへ保存する。
3. pass 1 treeをrestore、checkout、clean、copyし直さず、**同じworktreeのそのままの状態**で同じcommandをもう一度実行する。
4. **Pass 2**: pass 2後のbyte hashとtracked diffをpass 1直後と比較する。追加差分、canonical input変更、またはpass間のbyte差があればfailする。
5. `configure` について、canonical `configure.ac` / `auxdir/slurm.m4` 変更に直接対応する意図したhunkだけを候補patchへ保持する。
6. 全 `Makefile.in` 差分はbranch展開の検査evidenceを保存した後に破棄し、候補patchへ含めない。これは `CONTRIBUTING.md` のMakefile.am提出/Makefile.in非提出方針を維持する。
7. `aclocal.m4`、`config.h.in`、auxiliary scripts等、allowlist外generated fileに差分があれば候補patchをfailさせ、copyしない。
8. verified disposable treeから意図した `configure` だけをcandidate patchへ移し、candidate側で同じcontent hashであることを確認する。

## Hypothesized Root Cause

1. **Runtime rpath argument grouping**: `auxdir/slurm.m4` は `-Wl,-rpath=$libdir/slurm` を構成する。
   - compiler driverはcomma後をlinker argumentとして渡すため、ld64は `-rpath=<path>` という1 argumentを受け取る。
   - Apple ld64のcontractは `-rpath <path>` の2 argumentsで、equals formを受理しない。
   - GNU ldはequals formを受理するためLinuxで潜在していた。

2. **Object-format-specific reference embedding**: `make_ref.include` はGNU ld binary input modeとGNU objcopy section renameを前提とする。
   - `-z noexecstack` と `--format=binary` はApple ld64 optionsではない。
   - GNU binary objectが生成する `_binary_<file>_start/end/size` symbolsはMach-Oで自動的には得られない。
   - Apple toolchainではMach-O section、C ABI decoration、明示的boundary labelsが必要である。

3. **GNU-only dependency-retention option**: slurmd ruleは全toolchainへ `-Wl,--no-as-needed` を追加する。
   - `--no-as-needed` はGNU ldのas-needed stateを無効化するoptionで、ld64には存在しない。
   - Apple ld64は `-dead_strip_dylibs` がなければ明示dylibを通常direct load commandへ記録する。
   - link後artifactからDを作るとoracleが循環するため、input dylib IDからlink前にDを固定する必要がある。

4. **Regression coverage gap**: 既存testsuite rootには本checkをそのまま登録できるharness変数がなく、3 operationをApple ld64で実行してeffective argumentsとartifact contractを検査するtestが0件である。
   - 新規root harnessを作るとbugfix範囲を超える。
   - 単一standalone aggregate driverを規定commandで独立実行し、そのevidenceをrequired gateにすることが最小の解決である。

5. **Vacuous fix checking**: patched resultにbug conditionを再評価すると、修正によりforbidden optionが消えた時点で対象集合が空になり、何も検査せずProperty 1がpassし得る。
   - baseline `F(X)` から `C_F(X)` を評価し、同じXをmanifestへ凍結する必要がある。
   - driver/assertion/fixture変更後にbaselineを再取得しなければ、test oracleの意味がbaselineとpatchedでずれる。

6. **Cross-platform evidence coupling**: macOS作業環境だけではGNU/Linux preservation artifactを取得できない。
   - Linux runner contractを明示し、Darwin evidenceと独立に実行可能にする必要がある。
   - runner不在をDarwin operationのnot reachedと混同するとrequired preservation gateが消失する。

## Correctness Properties

次のpredicateをProperty 1へ使用する。

```text
FUNCTION expectedBehavior(input X, fixedResult R')
  INPUT: X of type BuildOperationInput
         R' = F'(X) of type BuildResult
  OUTPUT: boolean

  IF R'.exitStatus != 0 OR R'.requestedArtifactDoesNotExist THEN
    RETURN false
  END IF

  SWITCH X.kind
    CASE RuntimeRpath:
      RETURN X.path IN SUPPORTED_PATH_DOMAIN
             AND NOT R'.effectiveLdArgs CONTAINS ARG_PREFIX("-rpath=")
             AND R'.artifact.type == MachO
             AND R'.artifact.runtimePaths CONTAINS EXACT_VALUE(X.path)

    CASE EmbeddedReference:
      RETURN NOT R'.effectiveLdArgs CONTAINS CONSECUTIVE_ARGS("-z", "noexecstack")
             AND NOT R'.effectiveLdArgs CONTAINS SINGLE_ARG("--format=binary")
             AND R'.artifact.type == MachORelocatableObject
             AND R'.artifact.architecture == ConsumerArchitecture
             AND R'.artifact.platformTarget == ConsumerPlatformTarget
             AND R'.artifact.definesConsumerStartSymbol
             AND R'.artifact.definesConsumerEndSymbol
             AND R'.endAddress - R'.startAddress == LENGTH(X.payload)
             AND BYTES(R'.startAddress, R'.endAddress) == X.payload
             AND R'.consumerLinkHasNoBoundarySymbolUndefines

    CASE DependencyRetention:
      RETURN NOT R'.effectiveLdArgs CONTAINS SINGLE_ARG("--no-as-needed")
             AND NOT R'.effectiveLdArgs CONTAINS SINGLE_ARG("-dead_strip_dylibs")
             AND R'.artifact.type == MachO
             AND X.preLinkExpectedDirectDependencies
                 IS_SUBSET_OF R'.artifact.strongDirectLoadDependencies

    OTHERWISE:
      RETURN false
  END SWITCH
END FUNCTION
```

Property 1: Bug Condition - Frozen Apple ld64 Inputs Satisfy Artifact Contracts

_For any_ input X in the non-empty frozen bug input set `B_M` from a valid immutable baseline manifest, the fixed operation SHALL execute the same fixture input without re-evaluating `C_F` against `F'(X)` and SHALL satisfy `expectedBehavior(X, F'(X))`; manifest validation SHALL fail if any required fixture, operation category, input hash, or interface hash is absent or changed.

**Validates: Requirements 2.1, 2.2, 2.3, 2.5, 2.6, 2.7**

Property 2: Preservation - GNU/Linux Build Artifacts Remain Equivalent

_For any_ fixed preservation fixture executed on a preflighted Linux runner, the baseline commit and patched snapshot SHALL use the same compiler/binutils identities, configuration, configure options, environment, and fixture hashes, and the fixed operation SHALL produce the same ordered runtime paths, embedded symbols/payload/consumer output, or ordered direct dependency list as the baseline operation for the applicable operation kind.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4**

## Fix Implementation

### Change Architecture

```text
                            immutable baseline manifest M
                         from pristine F(X), C_F(X) == true
                                      |
                                      v
                               same frozen X only
                                      |
                                      v
configure.ac ------> DARWIN_BUILD ---> F'(X) ---> Darwin Property 1 evidence
       |                    |
       |                    +--> make_ref.include: Darwin CC + Mach-O .incbin
       |                    +--> slurmd Makefile.am: Darwin omits GNU flag
       |
auxdir/slurm.m4: common -Wl,-rpath,<P>

Linux runner: pristine baseline F ----- observable contracts -----+
Linux runner: patched F' ------------- same fixtures ------------+--> Property 2

Darwin evidence branch ------------------+
Linux evidence branch -------------------+--> final local completion gate
```

production C sourceは変更しない。条件判定はcanonical build systemに閉じ、runtime `#ifdef __APPLE__` を追加しない。

### Changes Required

#### 1. Toolchain Selection Conditional

**File**: `configure.ac`

既存alias判定と同じ `case "$host" in *darwin*)` styleを再利用し、Darwinだけtrueになる `DARWIN_BUILD` Automake conditionalを1つ追加する。

```text
case "$host" in
  *darwin*) darwin_build=yes ;;
  *)        darwin_build=no  ;;
esac
AM_CONDITIONAL(DARWIN_BUILD, test "x$darwin_build" = "xyes")
```

`LINUX_BUILD` の反転や `WITH_GNU_LD` の反転は使用しない。

#### 2. Portable Runtime Rpath

**File**: `auxdir/slurm.m4`

**Macro**: `X_AC_LIBSLURM`

runtime path部分だけを変更する。

```text
before: -Wl,-rpath=$libdir/slurm
after:  -Wl,-rpath,$libdir/slurm
```

`-L$(top_builddir)/src/api/.libs -lslurmfull`、`-export-dynamic`、path interpretationは変更しない。OS分岐や特殊path対応を追加しない。

#### 3. Mach-O Embedded Reference Object

**File**: `make_ref.include`

既存 `%.bino: %.txt` ruleだけを `DARWIN_BUILD` で分岐する。非Darwin branchは現在のGNU ld/objcopy経路を意味上維持する。Darwin branchのcommand-level contractは次である。

```make
%.bino: %.txt
	$(AM_V_GEN)cd "$(abs_srcdir)" && \
	ref_name='$(notdir $<)'; \
	case "$$ref_name" in ''|*[!A-Za-z0-9_.-]*) exit 1 ;; esac; \
	sym_name=$$(printf '%s' "$$ref_name" | sed 's/[^A-Za-z0-9_]/_/g'); \
	printf '%s\n' \
	  '.section __TEXT,__const' \
	  ".globl __binary_$${sym_name}_start" \
	  ".globl __binary_$${sym_name}_end" \
	  "__binary_$${sym_name}_start:" \
	  ".incbin \"$${ref_name}\"" \
	  "__binary_$${sym_name}_end:" | \
	$(CC) -x assembler -c -o "$(abs_builddir)/$*.bino" -
```

制約は次のとおりである。

1. source-root absolute pathをassembler literalへ埋め込まない。
2. fixed-format `printf '%s'` / `'%s\n'` だけを使用する。
3. start、`.incbin`、endの間にpadding、NUL、alignment、metadataを置かない。
4. C identifiers `_binary_<normalized>_start/end` に対応するdecorated symbolsを定義する。
5. `_size` symbol、consumer source、`src/common/ref.h`、既存build graphを変更しない。
6. `$(CPPFLAGS)`、`$(CFLAGS)`、`$(AM_CPPFLAGS)`、`$(AM_CFLAGS)` をassemblerへ渡さない。
7. Darwin branchは `$(LD)` と `@OBJCOPY@` を呼ばない。

#### 4. Darwin Dependency Retention

**File**: `src/slurmd/slurmd/Makefile.am`

`depend_ldflags += -Wl,--no-as-needed` をnon-Darwin branchだけに残す。

```text
if !DARWIN_BUILD
depend_ldflags += -Wl,--no-as-needed
endif
```

Darwin代替flagは追加しない。`depend_ldadd`、`slurmd_LDADD`、`slurmd_LDFLAGS`、library orderは変更しない。Dはinput dylib IDsからlink前に固定し、link後artifactから逆算しない。framework、weak/reexport dylib、archive、object、transitive dependencyが現れた場合は通常strong dylibへ一般化せず、要再設計またはnot reachedとして報告する。

#### 5. Single Standalone Aggregate Driver

**Selected path**: `testsuite/macos_build_compatibility.sh`

これは本bugfixで追加できる唯一のdriverである。helper driver、custom harness、custom logging framework、PBT frameworkを追加しない。`testsuite/Makefile.am` を変更せず、Automake suite登録を要求しない。driverは全operationを独立に実行し、最初のfailureで終了せず、全違反をstderrとmachine-readable evidenceへ蓄積して最後に単一statusを返す。

**Common CLI:**

```text
testsuite/macos_build_compatibility.sh \
  --mode MODE \
  --source-tree ABS_SOURCE_TREE \
  --build-root ABS_BUILD_ROOT \
  --evidence-dir ABS_EVIDENCE_ROOT \
  [--manifest ABS_MANIFEST] \
  [--baseline-contract ABS_BASELINE_CONTRACT]
```

`--source-tree`、`--build-root`、`--evidence-dir` はabsolute path必須で、evidence directoryはsource/build/git worktree外でなければならない。各modeは次で固定する。

| Mode | Purpose | Required extra input | Success output |
|---|---|---|---|
| `freeze-darwin-baseline` | pristine Fで`C_F`を評価しmanifestをatomic freeze | なし | `darwin/baseline/manifest.json` と `.sha256` |
| `verify-darwin-fix` | frozen XへF'を適用してProperty 1を検証 | `--manifest` | `darwin/patched/results.json` |
| `verify-aggregate-diagnostics` | 複数違反注入時の全件報告を検証 | `--manifest` | `darwin/diagnostics/results.json` |
| `capture-linux-baseline` | pristine baselineのProperty 2 oracleを取得 | なし | `linux/baseline/contracts.json` と `.sha256` |
| `verify-linux-preservation` | patched resultをbaseline oracleと比較 | `--baseline-contract` | `linux/patched/results.json` |

**Environment contract:**

- Common required: `HOST`, `PATH`, `LC_ALL=C`, `TZ=UTC`, `CC`, `LD`, `NM`, `FILE`
- Darwin modes: `OTOOL`
- Linux modes: `READELF`, `OBJCOPY`
- optional tool overrideを使う場合もabsolute executable pathをevidenceへ記録する
- driverはtool version output、environment allowlist、effective argumentsをevidenceへ保存する
- secrets、unbounded environment dump、user-specific dataを保存しない

**Exit status contract:**

- `0`: applicable modeの全required checksがpass
- `nonzero`（77以外）: schema/hash/preflight/verification/artifact/aggregate-reporting violation
- `77`: platformがmodeに適用外、またはcallerが明示したskip policyに該当

Linux runner自体が存在しない場合はdriver status 77へ変換しない。driver未実行としてorchestration levelで `BLOCKED_LINUX_RUNNER_UNAVAILABLE` を記録し、最終completionをblockedにする。

**Formal evidence paths:**

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

要件1.4は、次のstandalone invocation recordsが存在し、Darwin normal verificationが0、negative aggregate modeが期待どおりnonzeroを観測してdriver自身のmeta-checkが0になることで満たす。既存suite内のtest countを増やすことは要求しない。

#### 6. GNU/Linux Runner Contract

Linux preservation branchはmacOS hostから利用可能なLinux VM/container/remote runnerを使う。特定vendor、container image、orchestrator、repository dependencyは要求せず、独自runner implementationを追加しない。

**Preflight:**

1. `uname -s` が `Linux` である。
2. runner identity（VM image ID、container image digest、またはremote host build identity）、architecture、kernel、distributionを記録する。
3. compiler、linker、binutils、make、shell、Autotools、およびfixture inspection toolsのabsolute pathsとversionを記録する。
4. baseline commit objectを検証し、そのcommitからpristine baseline snapshot/worktreeを作成する。
5. candidate patchを同じbaselineへ適用したpristine patched snapshot/worktreeを別pathへ作成する。
6. 両snapshotはtracked diffが想定状態で、unexpected untracked filesがなく、build/evidence directoriesをsource外へ置く。
7. 同じrunner instance/image、`PATH`、`CC`、`LD`、`AR`、`AS`、`NM`、`OBJCOPY`、`READELF`、`MAKE`、locale、timezone、umask、configure options、dependency versionsをbaseline/patchedで使用する。
8. configure optionsはordered argvとしてevidenceへ保存し、baseline/patchedでbyte-equivalentであることを検証する。
9. fixed fixturesとstandalone driver interface hashesがDarwin manifestに定義したものと一致することを確認する。

baselineとpatchedの実行順によるcache contaminationを避けるため、別build rootを使用し、compiler cacheをdisableするか同じempty cache policyを適用する。runnerへproject source、fixture、patch以外の秘密情報を送らない。

Linux evidenceはEvidence Rootへ保存し、upstream candidate patchへ含めない。runnerがpreflightを満たさない場合は理由付きblockedとし、`not reached`、77、passにしない。

#### 7. Candidate Patch Allowlist and Audit

upstream candidate patchのallowlistは次の6 pathsだけである。

```text
configure.ac
auxdir/slurm.m4
make_ref.include
src/slurmd/slurmd/Makefile.am
configure
testsuite/macos_build_compatibility.sh
```

`testsuite/Makefile.am` はstandalone方式のため変更しない。全 `Makefile.in`、`.kiro/**`、baseline manifest/evidence、Linux evidence、validation reportは候補patch外である。

Auditはbaseline commitに対するtracked diffとuntracked filesの両方を対象にする。

- tracked changesはpathとhunkを検査し、allowlist pathでも3 operation、conditional、driver、直接生成されたconfigure hunk以外を拒否する。
- untracked filesは `git status --porcelain --untracked-files=all` 相当ですべて列挙する。選択driver以外のuntracked source/test fileは拒否する。
- `.kiro/**` はlocal specとして明示的にcandidateから除外し、stage/patch exportされていないことを確認する。
- evidenceとvalidation reportはsource tree外であることを確認する。誤ってtree内に生成された場合は候補patchをblockedにし、単にignoreして成功扱いしない。
- plugin/runtime、compatibility shim、platform API、security/auth、protocol/API/ABI、command option、configuration interpretationのhunkが0であることを確認する。

### Alternatives Considered

| Category | Alternative | Decision and Rationale |
|---|---|---|
| fix checking | patched resultへbug conditionを再評価 | forbidden option消失により母集団が空になるため不採用。pristine Fから凍結したXを使用する。 |
| manifest | baseline後にexpected valuesだけ更新 | test meaningのすり替えになるため禁止。interface変更時はpristine baselineから全再取得する。 |
| Linux evidence | macOS上の推測またはDarwin artifactで代用 | GNU/Linux preservationを証明できないため不採用。preflighted Linux runnerをrequired gateにする。 |
| runner | repository固有container/remote framework追加 | scopeとdependencyを増やすため不採用。既存VM/container/remote environmentの契約だけを定義する。 |
| regression harness | testsuite rootへ新しいAutomake harnessを追加 | 現行構造にTESTS等がなく、bugfix範囲を超えるため不採用。standalone driverを正式契約にする。 |
| rpath | Darwinだけ `-Xlinker -rpath -Xlinker P` | 動作可能だが分岐とtokenが増えるため、common comma formを採用する。 |
| reference | absolute source pathを `.incbin` へ埋め込む | assembler escapingが増えるため不採用。quoted `cd` とsafe basenameを使う。 |
| reference | `CCAS`/`AM_PROG_AS`追加 | custom ruleに対してscopeが大きく、CFLAGS継承問題もあるため不採用。 |
| dependency | `-needed_library`/`-needed-l` | operandごとの書換えが必要で、既定ld64 retentionで要件を満たすため追加しない。 |
| dependency oracle | link後artifactからDを作る | 循環oracleになるため不採用。input dylib IDsからlink前に固定する。 |
| generated files | Makefile.inをcandidate patchへ含める | CONTRIBUTING.md方針に反するため不採用。生成検査後に破棄する。 |
| CI | upstream CIをlocal completion dependencyにする | submission後にしか得られないため、follow-upとして分離する。 |

### Risks and Mitigations

| Risk | Mitigation | Validation |
|---|---|---|
| Property 1が空集合でpass | required fixture IDsと3 category non-emptinessをmanifest schema gateにする | freeze/verify双方でhard failure |
| baseline後にdriver/assertionが変わる | interface hashesを埋め込み、変更時はbaseline全再取得 | sidecar/embedded hash check |
| evidenceがcandidate patchへ混入 | Evidence Rootをworktree外に強制しtracked/untracked audit | source containment check + git status audit |
| Linux runner差で偽差分 | 同一runner/toolchain/config/environment/fixtures契約 | runner-preflightとbaseline/patched metadata比較 |
| runner不在をpass扱い | orchestration statusをBLOCKEDに固定 | final gateがLinux evidence absenceを拒否 |
| Mach-O underscoreを誤る | decorated double-underscore symbolsを明示 | `nm -g` + unchanged-style consumer link |
| payload boundaryにpaddingが入る | `.incbin` とend label間にdirectiveを置かない | address差と全bytes比較 |
| object targetがconsumerと不一致 | native baseline境界とtarget inspectionを必須化 | `file`/`otool -hv` comparison |
| ld64がunused dylibを除去 | effective argsでdead-stripを拒否しpre-link Dを比較 | known-ID 1/2 dylib fixtures |
| generator version drift | exact version preflightと同一tree連続2-pass | pass 1/2 hash/diff equality |
| Makefile.inがpatchへ混入 | allowlistから除外し全差分破棄 | tracked/untracked audit |
| standalone driverが最初のfailureで終了 | operation-level result集約後にstatus決定 | multi-violation meta-fixture |
| full build blockerをfix failure扱い | operation invocation到達性とlimited reproductionを分離 | not reached reason + equivalence record |
| scope creep | 6-path allowlistとhunk audit | baseline diff + untracked file audit |

### Rollback Strategy

変更はstate migration、API/ABI、runtime data変更を持たないためsource-level revertでrollbackできる。

1. `configure.ac` の `DARWIN_BUILD` と対応するgenerated `configure` hunkをrevertする。
2. `make_ref.include` のDarwin branchを除き、既存GNU ruleへ戻す。
3. `auxdir/slurm.m4` のcomma formをequals formへ戻す。
4. slurmd conditionalを除きunconditional `--no-as-needed` を戻す。
5. standalone driverを除く。
6. exact generator procedureを実行し、Makefile.in差分を破棄してallowlist auditを行う。

baseline/evidenceはcandidate patch外なのでrollback対象ではない。rollbackはDarwin bugを再導入するため3 operationを1 bugfix unitとして扱う。

## Testing Strategy

### Validation Approach

検証は2 branchを独立に実行する。Darwin branchはLinux runnerを待たずにbaseline/fix evidenceを完成でき、Linux branchはDarwin full buildを要求せずpreservation evidenceを完成できる。最終local completion gateだけが両方のPASSを要求する。

```text
Darwin branch:
  pristine baseline preflight
    -> freeze immutable manifest
    -> validate non-empty C_F records
    -> apply candidate patch
    -> verify same frozen X against F'
    -> aggregate diagnostics
    -> actual rules or equivalent reproductions
    -> DARWIN_EVIDENCE_PASS

Linux branch:
  Linux runner preflight
    -> pristine baseline snapshot + pristine patched snapshot
    -> capture baseline observable contracts
    -> verify patched contracts with identical environment
    -> LINUX_PRESERVATION_PASS

Final gate:
  DARWIN_EVIDENCE_PASS AND LINUX_PRESERVATION_PASS
  otherwise FAIL or BLOCKED; never infer one branch from the other
```

すべてのrecordsにはtoolchain version、fixture ID、input value/digest、effective arguments、exit status、artifact type、inspection resultを含める。full macOS buildはgateにしない。

### Exploratory Bug Condition Checking

**Goal**: pristine unfixed codeでcounterexampleをsurfaceし、`C_F(X)` がtrueのinputをimmutable manifestへ凍結する。

**Command contract:**

```sh
HOST=<darwin-triplet> CC=<apple-clang> LD=<apple-ld> NM=<nm> OTOOL=<otool> FILE=<file> \
LC_ALL=C TZ=UTC \
testsuite/macos_build_compatibility.sh \
  --mode freeze-darwin-baseline \
  --source-tree <ABS_PRISTINE_BASELINE_TREE> \
  --build-root <ABS_BASELINE_BUILD_ROOT> \
  --evidence-dir <ABS_EVIDENCE_ROOT>
```

**Test Cases:**

1. `rpath-absolute` と `rpath-nested`
2. `reference-text`、`reference-binary`、`reference-multidot-certgen`
3. `retention-one-dylib` と `retention-two-dylib`
4. `classification-missing-input`

**Freeze acceptance:**

- 7 bug fixturesすべてが期待したoperation categoryとcounterexampleを持つ。
- 3 categoryが各1件以上で、`B_M` が空でない。
- missing-input fixtureはnot reachedでB_M外である。
- manifest/schema/interface/input hashesがvalidである。
- 製品build ruleはpristine baselineのままである。

いずれかを満たさない場合、manifestはpublishせずroot causeを再仮説化する。

### Fix Checking

**Goal**: `B_M` の同じXすべてについて `expectedBehavior(X, F'(X))` を検証する。

**Command contract:**

```sh
HOST=<darwin-triplet> CC=<apple-clang> LD=<apple-ld> NM=<nm> OTOOL=<otool> FILE=<file> \
LC_ALL=C TZ=UTC \
testsuite/macos_build_compatibility.sh \
  --mode verify-darwin-fix \
  --source-tree <ABS_PATCHED_TREE> \
  --build-root <ABS_PATCHED_BUILD_ROOT> \
  --evidence-dir <ABS_EVIDENCE_ROOT> \
  --manifest <ABS_EVIDENCE_ROOT>/darwin/baseline/manifest.json
```

**Pseudocode:**

```text
M := loadAndValidateImmutableManifest()
B_M := frozenBugInputs(M)
ASSERT requiredCategories(B_M) == {RuntimeRpath, EmbeddedReference, DependencyRetention}
FOR ALL X IN B_M DO
  result := F'(X)
  ASSERT expectedBehavior(X, result)
END FOR
```

DriverはF'のresultに `C_F` を再評価しない。forbidden optionsが消えたことはexpectedBehaviorの一部であり、input除外理由ではない。

**Darwin artifact inspection:**

- Rpath: traceに `-rpath=` がなく、`LC_RPATH` にmanifest Pとのexact matchがある。
- Reference: relocatable arm64 Mach-O、consumer target一致、decorated symbols、`end-start == N`、全payload bytes一致、consumer linkにboundary undefinedなし。
- Dependency: `--no-as-needed` と `-dead_strip_dylibs` がなく、manifestのpre-link Dがstrong direct loadsへ包含される。

### Aggregate Diagnostics Checking

複数違反を同時注入するmeta-fixtureで、全operation名、全forbidden option、全artifact contract violationを列挙してnonzeroになることを確認する。次にdriverのmeta-checkが「期待したnonzeroと全診断を観測した」ことを0で報告する。custom loggerは追加せず、driverのstderrとJSON evidenceだけを使用する。

```sh
testsuite/macos_build_compatibility.sh \
  --mode verify-aggregate-diagnostics \
  --source-tree <ABS_PATCHED_TREE> \
  --build-root <ABS_DIAGNOSTICS_BUILD_ROOT> \
  --evidence-dir <ABS_EVIDENCE_ROOT> \
  --manifest <ABS_EVIDENCE_ROOT>/darwin/baseline/manifest.json
```

### Preservation Checking

**Goal**: preflighted Linux runner上で、baseline Fとpatched F'のobservable contractsが同一であることを確認する。

**Baseline command:**

```sh
HOST=<linux-triplet> CC=<cc> LD=<ld> NM=<nm> FILE=<file> READELF=<readelf> OBJCOPY=<objcopy> \
LC_ALL=C TZ=UTC \
testsuite/macos_build_compatibility.sh \
  --mode capture-linux-baseline \
  --source-tree <ABS_PRISTINE_BASELINE_TREE> \
  --build-root <ABS_LINUX_BASELINE_BUILD_ROOT> \
  --evidence-dir <ABS_EVIDENCE_ROOT>
```

**Patched command:**

```sh
HOST=<same-linux-triplet> CC=<same-cc> LD=<same-ld> NM=<same-nm> FILE=<same-file> \
READELF=<same-readelf> OBJCOPY=<same-objcopy> LC_ALL=C TZ=UTC \
testsuite/macos_build_compatibility.sh \
  --mode verify-linux-preservation \
  --source-tree <ABS_PRISTINE_PATCHED_TREE> \
  --build-root <ABS_LINUX_PATCHED_BUILD_ROOT> \
  --evidence-dir <ABS_EVIDENCE_ROOT> \
  --baseline-contract <ABS_EVIDENCE_ROOT>/linux/baseline/contracts.json
```

**Pseudocode:**

```text
ASSERT linuxRunnerPreflight == PASS
ASSERT baselineEnvironment == patchedEnvironment
ASSERT baselineFixtureHashes == patchedFixtureHashes
FOR ALL X IN preservationFixtures DO
  original := executeBaselineOperation(X)
  fixed := executeFixedOperation(X)
  ASSERT observableArtifactContract(original)
         == observableArtifactContract(fixed)
END FOR
```

binary全体のhashはtimestamp、UUID、tool metadataで変わり得るためpropertyにしない。

- Rpath: normal/nested Pのordered `RPATH`/`RUNPATH` valuesを比較する。
- Reference: text/binary/multi-dot fixtureのsymbols、linkage、payload、end-start、consumer-visible bytesを比較し、GNU ld/objcopy command pathを確認する。
- Dependency: known-ID 1/2 librariesのordered `DT_NEEDED` を比較し、patched GNU/Linux operationが `--no-as-needed` を維持することを確認する。

Linux runnerがなければこのsectionは `BLOCKED_LINUX_RUNNER_UNAVAILABLE` であり、Darwin evidence作成は続行できるが最終completionには到達しない。

### Unit Tests

- immutable manifest schema、canonical serialization、sidecar/embedded hashes、required fixture/category non-emptiness
- manifest overwrite拒否とinterface hash mismatch時のbaseline reacquisition要求
- normal/nested Pのzero status、forbidden argument不在、exact `LC_RPATH`
- text、binary、multi-dot reference objectのtarget、symbols、boundaries、bytes、consumer link
- known-ID 1/2 dylibのpre-link Dとstrong direct dependency包含
- missing inputのnot reached分類
- multi-violation aggregate report
- Linux runner metadata/config/environment equality preflight
- candidate patchのtracked/untracked allowlist audit

### Property-Based Tests

新しいPBT frameworkやrandom corpusは追加しない。Property 1/2はfixed fixturesのparameterized assertionsとして実装する。manifestにfixture IDs、input hashes、effective argumentsを凍結し、失敗を再現可能にする。

### Integration Tests

1. **Actual generated rpath rule**: 到達可能な最小target、またはequivalent reproductionでnormal/nested Pを検査する。
2. **Actual reference graph**: `.txt -> .bino -> lib_ref.la -> consumer` を通し、source-root absolute pathがassembler literalへ入らず、target/symbol/payload/consumer contractを満たすことを確認する。
3. **Actual dependency rule**: slurmd linkへ到達できればaffected strong dylibsからDを事前固定する。未到達ならknown-ID fixture reproductionを使用する。
4. **Linux baseline/patched**: 同一runner contractで3 observable contractsを比較する。
5. **Bootstrap**: exact version preflight後、同じdisposable patched treeでrestoreなしの2-pass `autoreconf --force` を実行する。
6. **Patch scope**: 6-path allowlistに対してtracked diffとuntracked filesの両方をauditする。

### Validation Procedure

#### Darwin Fix Evidence Branch

1. pristine baseline commit、Apple toolchain、driver/assertion/fixture interfaceを記録する。
2. standalone driverを `freeze-darwin-baseline` modeで実行する。
3. manifest non-emptiness、required IDs/categories、schema/hashを検証する。
4. candidate build-rule changesを適用する。
5. 同じmanifestで `verify-darwin-fix` と `verify-aggregate-diagnostics` を実行する。
6. actual generated operationを優先し、周辺blockerで未到達ならoperation別にnot reached reasonを記録してequivalent limited reproductionを実行する。
7. `DARWIN_EVIDENCE_PASS` をEvidence Rootへ記録する。

#### GNU/Linux Preservation Evidence Branch

1. Linux runner preflightを実行する。runnerがなければこのbranchと全体completionをblockedにする。
2. baseline commitのpristine snapshotと、同じbaselineへcandidate patchを適用したpristine patched snapshotを作る。
3. 同一runner/toolchain/config/configure options/environment/fixturesを検証する。
4. `capture-linux-baseline` と `verify-linux-preservation` を別build rootsで実行する。
5. `LINUX_PRESERVATION_PASS` をEvidence Rootへ記録する。

#### Generation and Scope Branch

1. Autoconf 2.72 / Automake 1.18.1 preflightを実行する。
2. disposable pristine patched treeでpass 1を実行する。
3. restoreなしの同じtreeでpass 2を実行し、byte hashes/diffsを比較する。
4. intended `configure` diffだけをcandidateへ保持し、全Makefile.in差分を破棄する。
5. tracked diffとuntracked filesを6-path allowlistへ照合する。
6. `.kiro/**`、evidence、validation reportがcandidate patch外であることを確認する。

#### Final Local Completion Gate

次のすべてが必要である。

- `DARWIN_EVIDENCE_PASS`
- `LINUX_PRESERVATION_PASS`
- aggregate diagnostics PASS
- actual ruleまたはequivalent limited reproduction evidence
- generation two-pass idempotence PASS
- tracked/untracked scope audit PASS
- unsupported macOS disclaimerを含むpatch外validation report

Linux runner不在またはLinux preflight failure時は `BLOCKED` であり、Darwin branchがPASSでも全体完了ではない。

### Post-Submission Follow-up

コミュニティ提出後のupstream Linux CI結果確認は重要だが、submission前には実行不能なため、本設計の実装完了条件、task dependency graph、local completion gateには含めない。提出後follow-upとして結果を確認し、failureがcandidate patchに関連する場合は別途修正・再検証する。

### Requirement Traceability

| Requirement | Design Element | Verification |
|---|---|---|
| 1.1 | `C_F`, frozen rpath fixtures | baseline manifest counterexamples |
| 1.2 | `C_F`, frozen reference fixtures | baseline manifest counterexamples |
| 1.3 | `C_F`, frozen retention fixtures | baseline manifest counterexamples |
| 1.4 | Single Standalone Aggregate Driver | explicit standalone invocation evidence; no suite registration required |
| 2.1 | Property 1; portable rpath | same frozen X + exact `LC_RPATH` |
| 2.2 | Property 1; Darwin `.incbin` | same frozen X + forbidden args absence + Mach-O object |
| 2.3 | Property 1; pre-link D | same frozen X + strong direct loads |
| 2.4 | aggregate diagnostics mode | multi-violation full report |
| 2.5 | manifest non-empty category gate | all 3 independent operations from same frozen baseline set |
| 2.6 | explicit symbols/boundaries/bytes | text/binary/multi-dot fixtures + consumer link |
| 2.7 | actual/limited reproduction record | equivalence fields + not reached classification |
| 2.8 | 6-path allowlist and scope | tracked/untracked audit |
| 3.1 | Property 2 Linux runner contract | ordered runtime path comparison |
| 3.2 | Property 2 Linux runner contract | symbol/linkage/payload comparison |
| 3.3 | unchanged consumer | consumer-visible byte comparison |
| 3.4 | nonDarwin retention branch | ordered `DT_NEEDED` comparison |
| 3.5 | exact generator procedure | same-tree restore-free two-pass equality |
| 3.6 | candidate allowlist | tracked diff + untracked files audit |
| 3.7 | explicit production-code exclusion | plugin/runtime zero-hunk audit |
| 3.8 | explicit API/security exclusion | security/protocol/API/ABI zero-hunk audit |
| 3.9 | patch-external report | unsupported macOS disclaimer assertion |
| 3.10 | independent branches/status model | Darwin not reached separation; Linux blocked semantics |

### Completion Criteria

実装完了は、frozen manifestによるnon-vacuous Property 1、preflighted Linux runnerによるProperty 2、aggregate diagnostics、actual ruleまたは同値reproduction、restoreなし同一treeの2-pass generation、6-path tracked/untracked auditがすべてpassした場合に限る。

Linux preservation evidenceがない場合は、Darwin evidenceを完成・保存してよいが、全体statusはblockedである。full macOS build、plugin/daemon/job runtime、特殊path、nonnative Darwin target、またはpost-submission upstream CIはlocal completion判定に使用しない。upstream CIは提出後follow-upとして扱う。
