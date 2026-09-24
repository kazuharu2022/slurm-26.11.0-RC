# SMD-401 PMIx v6 multi-node direct-launch

- 状態: `PASS_PMIX_V6_MULTINODE_DIRECT / TEMPORARY_NODE_NAME_ALIAS_REQUIRED / ROLLBACK_PASS`
- 日時: 2026-09-24 15:30–17:13 JST
- controller / Linux worker: `ubuntu2504` / x86-64 / Ubuntu 24.04
- macOS worker: `PC-210` / arm64 / macOS 26.5.1
- Slurm: `26.11.0-0rc1`
- PMIx: `6.1.0`
- production変更: Ubuntu plugin 1 fileの一時配置とUbuntu `slurmd`再起動を5回実施。各回rollback完了。Mac `/etc/hosts`の一時aliasもbyte完全復元
- Job投入: あり（失敗・診断Jobを含み、全て終了・回収済み）

## 目的

SMD-401で未測定だった2-nodeのSlurm PMIx direct-launchを、Ubuntu `ubuntu`と
macOS `PC-210`へ1 taskずつ配置して確認する。SMD-402でOpen MPI 5.0.11の
mixed-architecture通信は既にPASSしているため、今回はMPI実装を再導入せず、公式MPI Guideにある
PMIx clientの直接試験に限定する。

成功条件は、両nodeが同じPMIx namespaceへ参加し、rank 0が公開した値42をFence後にrank 0/1が
取得すること、cancel時に両PID・step・割当を回収すること、試験後にUbuntuの一時pluginを削除して
元のproduction状態へ戻すことである。

参照:

- https://slurm.schedmd.com/mpi_guide.html#pmix_testing
- https://docs.openpmix.org/en/v6.1.0rc1/installing-pmix/quickstart.html
- https://github.com/openpmix/openpmix/releases/tag/v6.1.0

## read-only preflight

Ubuntuでは`slurmctld`、`slurmdbd`、`slurmd`がactiveで、PIDはそれぞれ
197928、189104、198005だった。`ubuntu`と`PC-210`はIDLE、CPUAlloc/AllocMemは0、
queueは空だった。production `srun --mpi=list`は`pmi2`だけで、PMIx pluginはなかった。

MacにはPMIx 6.1.0、Open MPI 5.0.11、production `mpi_pmix_v6.so`があり、
`srun --mpi=list`は`pmix_v6`を列挙した。Mac `slurmd`はlaunchd PID 41674でrunningだった。
SMD-402 cleanupにより両hostの旧isolated Open MPI treeは存在しなかった。

## Ubuntu Compose isolated build

Ubuntuホストへpackageを追加せず、`ubuntu:24.04` container内だけへbuild dependencyを導入した。
builderのbase image digestは
`sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3`、
canonical builder image IDは
`sha256:3e436f53a85c5b18c17afdf7251f906c55acacd77967eb6917f268595f59fee8`である。

PMIx 6.1.0 release tarballは公式SHA-1
`f276e91075aed84ff595eb004f7d69118596e869`と一致し、今回取得したSHA-256は
`bb9021c8e100a376f5070ecca727f83a29b5f652dfe381793b88daa79a3b98a2`だった。

失敗履歴は次のとおり保持した。

1. Attempt 1: `--with-libevent=/usr`だけではUbuntu multiarch library directoryを検出できず停止。
2. Attempt 2: PMIxとplugin build後、strict C11で`PATH_MAX`が未定義となりprobe build停止。
3. Attempt 3: pluginがPMIx directoryとlibrary名を別文字列で保持するため、絶対文字列validatorが誤停止。
4. Attempt 4: RUNPATHが`/usr/lib64`との複数pathであるため、単独RUNPATH validatorが誤停止。
5. Attempt 5: buildは完了したが、manifestにcontainer内`/input` pathを含めたためhost readback停止。
6. Attempt 6: 入力manifestと生成物manifestを分離し、完全PASS。

Attempt 1～4の出力はUbuntuの
`/tmp/smd401-pmix6-attempt1-failed`～`attempt4-failed`、Attempt 5は
`/tmp/smd401-pmix6-attempt5-build-pass-readback-manifest-fail`へ保持した。

Compose isolated-build artifact（runtime Attempt 1で不採用）:

| artifact | SHA-256 |
|---|---|
| Ubuntu `mpi_pmix_v6.so` | `1a761fc9e3a84f1dc96371605407322bb97a85dddb2f1edd5b0b76b52cbc2be5` |
| Ubuntu PMIx probe | `ff8a9d7506d168a1dba4f1f6de4586c395dcadff2ad621eaac2fe15e4c915de1` |
| Ubuntu `libpmix.so.2` | `46c72eeda9dbc8798fb3308435bc8a511fb0d89a2715c29df5ebb20a0445cc12` |
| Mac PMIx probe | `26be32d73a3f9ced59b1cf3926cfa9efb967a8f4d5e86f3e8f43a8d142f9b6e5` |
| 共通probe source | `141744df2dcffdd72748ce1da15c31f56c8b0b0e1ac0edb65bdb0f4d23b85fb2` |

Ubuntu pluginとprobeはx86-64 ELF、Mac probeはarm64 Mach-Oである。Ubuntu probeは
`/tmp/smd401-pmix6/pmix/lib/libpmix.so.2`、Mac probeは
`/opt/homebrew/opt/pmix/lib/libpmix.2.dylib`へ解決し、いずれもPMIx 6.1.0である。

一時`PluginDir`だけを使ったUbuntu client loadでは`pmix_v6`を列挙し、stderrは0 byteだった。
production `slurm.conf`、`slurmd`、`slurmctld`のSHA-256は既存値と一致し、両node IDLE、
queue空を再確認した。

## production runtime Attempt 1 / FAIL

ユーザー承認後、Composeで作成したcandidate
`1a761fc9e3a84f1dc96371605407322bb97a85dddb2f1edd5b0b76b52cbc2be5`をUbuntuの
`/usr/local/slurm/26.11.0/lib/slurm/mpi_pmix_v6.so`へ一時配置し、Ubuntu `slurmd`だけを
再起動した。PIDは198005から1097817へ変わり、`slurmctld` 197928、`slurmdbd` 189104、
Mac `slurmd` 41674は不変だった。独立readbackでplugin hash、`pmix_v6`列挙、両node IDLE、
CPUAlloc 0、queue空、production設定・binary hash不変を確認した。

Job 700の`mpi=none` preflightでは、Ubuntu x86-64とMac arm64のprobe hashを各nodeで確認した。
続く2-node PMIx Job 701では、Mac rank 0がnamespace `slurm.pmix.701.0`、size 2、値42、
Fence PASSまで出力したが、Ubuntu rank 1はplacement出力前に起動完了せず、Jobは2分29秒で
`TIMEOUT`となった。`srun`は`StepId=701.0 aborted before step completely launched`と
`Timed out waiting for job step to complete`を記録した。会計上stepが`COMPLETED 0:0`である一方、
jobが`TIMEOUT 0:0`である不整合もそのまま保持する。driverはFAIL markerを出し、対象Jobを回収した。

## failure isolation

同じcandidateでUbuntu単独Job 702もstep起動完了前にtimeoutした一方、Mac単独Job 703は
namespace `slurm.pmix.703.0`、rank 0、size 1、値42、Fence PASSで正常終了した。したがって、
2-node通信やprobeのアルゴリズムより前に、Ubuntu側PMIx plugin runtimeが失敗している。

Job 704～707ではUbuntu単独の`/bin/true`起動、`slurmstepd` process追跡、core/kernel log、
`slurmd` thread状態を順に確認した。いずれも診断後にcancelし、queue、割当、node状態を回収した。
`/bin/true`でもjob用`slurmstepd`が継続存在する前に失敗し、core dump、kernel crash message、
PMIx固有error logは得られなかった。Compose側のSlurm configure/build条件とproduction Slurmの
build条件が異なることは確認できたが、それを実行時失敗の確定root causeとはまだ扱わない。

## rollback / PASS

失敗candidateをhash照合後に削除し、Ubuntu `slurmd`だけを再起動した。PIDは1097817から
1101850へ変わった。独立readbackでtarget不在、production `srun --mpi=list`から`pmix_v6`消失、
3 service active、両node IDLE・CPUAlloc 0、queue空、通常job用`slurmstepd`残留0を確認した。
`slurm.conf`、`slurmd`、`slurmctld`のSHA-256はpreflight値と一致し、Mac PID 41674も不変だった。

## production exact-source candidate

Ubuntu上に残っていたproduction元ビルドツリー
`/tmp/slurm-smd407-certgen-linux-Wl0IsB/source`の`slurmd`と`mpi_pmi2.so`が、production実体と
それぞれSHA-256
`2c445fdf614b0554aa76f7b0df272ec6c0ea8af456736b3fa66a28a41847ed14`、
`8b0494eb67e31f1cdd8e2a5188f99c1759ebba08f38892bb32d41e83c2c18e87`で一致した。

修正candidate作成の失敗・棄却履歴も保持した。

1. Attempt 1: `tera`では元treeの親directoryを走査できず、入力hash取得前に停止。
2. Attempt 2: configured済みsourceへのVPATH configureをAutoconfが拒否して停止。
3. Attempt 3: 未構成の新しいsourceからhost buildできたが、production sourceと複数file hashが異なるため棄却。
4. Attempt 4: production元treeを`/tmp`へ複製し、その複製内だけで同じprefixとPMIx指定を追加してPASS。

Attempt 4の生成`config.h`はproduction元`config.h`との差が`HAVE_PMIX=1`だけで、plugin makeの
warning/errorは0だった。candidateはx86-64 ELF、PMIx 6.1.0の
`/tmp/smd401-pmix6/pmix/lib/libpmix.so.2`を参照し、依存欠落はない。

| artifact | SHA-256 |
|---|---|
| production exact-source Ubuntu `mpi_pmix_v6.so` | `1c4b8d44eaf8279d24611c52c70e858410e449385a7627bc97b8be6a552668bb` |
| Ubuntu `libpmix.so.2` | `46c72eeda9dbc8798fb3308435bc8a511fb0d89a2715c29df5ebb20a0445cc12` |

一時`PluginDir`によるclient loadはgeneric `pmix`と`pmix_v6`を列挙し、stderrは0 byteだった。
この確認ではproduction配置、Job投入、daemon restartを行っていない。

## production runtime Attempt 2 / Ubuntu PASS・2-node FAIL

追加承認後、exact-source candidate
`1c4b8d44eaf8279d24611c52c70e858410e449385a7627bc97b8be6a552668bb`をUbuntuのproduction
plugin directoryへ一時配置し、Ubuntu `slurmd`だけを再起動した。PIDは1101850から1130846へ
変わった。`slurmctld` 197928、`slurmdbd` 189104、Mac `slurmd` 41674は不変だった。

Job 708の2-node `mpi=none` preflightは、Ubuntu probe
`ff8a9d7506d168a1dba4f1f6de4586c395dcadff2ad621eaac2fe15e4c915de1`とMac probe
`26be32d73a3f9ced59b1cf3926cfa9efb967a8f4d5e86f3e8f43a8d142f9b6e5`を各nodeで確認してPASSした。
新設したUbuntu単独PMIx gateのJob 709はnamespace `slurm.pmix.709.0`、rank 0、size 1、値42、
Fence PASSとなり、job/stepとも`COMPLETED 0:0`、stderr 0 byteだった。したがってexact-source再buildで
Attempt 1のUbuntu起動失敗は解消した。

Job 710ではMac rank 0とUbuntu rank 1のpayloadがともに起動した。Mac rank 0はnamespace
`slurm.pmix.710.0`、size 2、値42、Fence PASSまで到達したが、Mac側PMIx pluginがdirect connection先
`ubuntu:6818`を名前解決できず、次を記録した。

```text
error: _xgetaddrinfo: getaddrinfo(ubuntu:6818) failed: nodename nor servname provided, or not known
error: slurm_set_addr: Unable to resolve "ubuntu"
error: mpi/pmix_v6: _tcp_connect: PC-210 [0]: ... Can't find address for host ubuntu, check slurm.conf
error: mpi/pmix_v6: pmixp_dconn_connect: PC-210 [0]: ... Cannot establish direct connection to ubuntu (1)
```

Job 710はjob `FAILED 0:9`、step `CANCELLED by 3001 0:9`となった。driver recoveryで対象Jobを回収し、
queue空、両node IDLE・CPUAlloc 0、通常job用stepd残留なしを確認した。このAttemptのfailure boundaryは
PMIx pluginのbinary互換性ではなく、Slurm `NodeName=ubuntu`のMac側名前解決である。

## Attempt 2 rollback / PASS

承認済みrollback driverはcandidate hashを照合してpluginを削除し、Ubuntu `slurmd`だけを再起動した。
PIDは1130846から1131492へ変わった。独立readbackでplugin不在、production
`srun --mpi=list`が`none`、`cray_shasta`、`pmi2`だけを列挙、3 service active、両node IDLE・
CPUAlloc 0、queue空を確認した。`slurmctld` 197928、`slurmdbd` 189104、Mac `slurmd` 41674は不変である。

Ubuntu production hashは次の値を維持した。

- `slurm.conf`: `1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68`
- `slurmd`: `2c445fdf614b0554aa76f7b0df272ec6c0ea8af456736b3fa66a28a41847ed14`
- `slurmctld`: `834e8968209e0a989cf4bbdb917d14a5f0ae41b0db253aeb3ad7b9b458972c70`

## job-scoped direct connection disable案

Mac `/etc/hosts`には`192.168.10.180 ubuntu2504`だけがあり、`ubuntu` aliasはない。Ubuntu側の
`/etc/hosts`では`ubuntu`が`192.168.10.118`、Slurmの`NodeAddr`は`192.168.10.180`であるため、
system-wide alias追加は既存名称との意味差を生む。

同梱sourceでは環境変数`SLURM_PMIX_DIRECT_CONN`をPMIx step初期化時に読み、falseの場合はdirect TCPを
使わずSlurm protocolへ送る。そこで次のretry driverは、Ubuntu単独gateをdefault direct connectionのまま
再確認し、2-node PMIx正常・cancel Jobだけへ`SLURM_PMIX_DIRECT_CONN=0`を設定するよう修正した。
両taskの環境値も照合する。`/etc/hosts`、`mpi.conf`、`slurm.conf`、Mac daemonは変更しない。
この案はsource確認とdriver静的検証の段階であり、runtime結果ではない。

## job-scoped retry Attempt 3 / HARNESS_FALSE_NEGATIVE

承認後、修正版driver SHA-256
`6aea32afa9a42b76299efb09d99cde670ddd9a9e01e353f8c4ef5e19b72dc953`をremoteへ転送し、
hash、`/bin/sh -n`、未承認時rc 64、plugin不在、3 service active、両node IDLE、queue空を確認した。
exact-source candidateを再配置し、Ubuntu `slurmd`を1131492から1132109へ再起動した。

2-node正常系のpayload shellは起動したが、driverがpayload環境にも
`SLURM_PMIX_DIRECT_CONN=0`が残ることを要求してrc 98で停止した。PMIx pluginがこの値を読むのは
task起動前の`slurmstepd`初期化であり、payload環境への残存はPMIx通信の成功条件ではないため、
これは本体結果ではなく`HARNESS_FALSE_NEGATIVE_ENV_VISIBILITY`とした。remote run directoryは
`/tmp/slurm-smd401-pmix6-multinode-20260924T165817`である。

対象Job回収後、candidateを削除してUbuntu `slurmd`を1132109から1132574へ再起動した。
独立readbackでproduction復旧を確認した。

## job-scoped retry Attempt 4 / FAIL

payload環境guardだけを除去し、srun起動時の`SLURM_PMIX_DIRECT_CONN=0`は維持したdriver
`1813fc675fee6d896aa387adaea606ac01e7934d62130f26f6b49ba48431867f`で再試験した。
remote hash、構文、plugin不在、services、node、queueのpreflightはPASSした。candidate配置後、Ubuntu
`slurmd`は1132574から1133038へ変わった。

2-node正常系は完了せず、Job時間上限後にclient rc 143となった。driverはFAIL markerを出して対象Jobを
回収した。remote run directoryは
`/tmp/slurm-smd401-pmix6-multinode-20260924T170214`である。job-scoped値がremote `slurmstepd`で
有効化されなかったのか、direct無効時のSlurm protocol経路が別要因で停止したのかは、この出力だけでは
区別できない。したがってjob-scoped案をPASSとはしない。

詳細remote logと会計情報のローカル取得は、機密情報を含み得る診断データの未承認exportとして安全審査で
拒否された。迂回せず、raw evidenceは上記remote run directoryへ保持した。

candidateをhash照合して削除し、Ubuntu `slurmd`を1133038から1133509へ再起動した。独立readbackで
plugin不在、production MPI列挙が`none`、`cray_shasta`、`pmi2`のみ、3 service active、両node IDLE・
CPUAlloc 0、queue空を確認した。`slurmctld` 197928、`slurmdbd` 189104、Mac `slurmd` 41674、
production hashは不変である。

## temporary Mac host alias retry Attempt 5 / PASS

追加承認後、Mac `/etc/hosts`のSHA-256
`e8595fbd163b74eb6191e76dbbaf5f7756c362a9a8c72ae63f7d0665a07a5522`と、`ubuntu` entry不在を
再確認した。管理者認証後、backup付きinstallerで`192.168.10.180 ubuntu`を一時追加した。変更後SHAは
`4e379f02702cafde83b4b2e71e8d0060040596c03baa2d57eac71abb4afa5a28`で、Macの名前解決と
`ubuntu:6818`へのTCP接続はPASSした。

既定のdirect connectionへ戻したruntime driver SHA-256は
`4243c5bdb55d1e70ae4e20b2ce79aaf7d1346e661099db7ce9cea18cec7c7290`である。remote hash、構文、
plugin不在、3 service active、両node IDLE、queue空を確認後、exact-source candidateを一時配置した。
Ubuntu `slurmd`は1133509から1134264へ再起動し、`slurmctld`、`slurmdbd`、Mac `slurmd`は不変だった。

runtime driverは次の完了markerを返した。

```text
SMD401_PMIX6_MULTINODE_COMPLETE single_job=718 success_job=719 cancel_job=720 cleanup_job=721 nodes=ubuntu:x86_64,PC-210:arm64 ranks=2 cancel_rc=143 communication=PMIX_PUT_GET_FENCE_PASS pmix_direct_conn=enabled cancel_cleanup=PASS production_unchanged=PASS
```

- Job 718: Ubuntu単独PMIx gateをPASS。
- Job 719: Ubuntu x86-64とMac arm64の2 rankが同じPMIx namespaceへ参加し、値42のPut/Get/FenceをPASS。job/step正常終了をdriverが照合。
- Job 720: 両rankのFence完了とPID記録後にcancel。client rc 143、job/step取消、両PID消滅をdriverが照合。
- Job 721: 両nodeでPID・ready directory残留なしを確認。

Attempt 2で失敗したdirect TCP経路がhost alias追加だけでPASSしたため、2-node failureの原因は
MacからSlurm `NodeName=ubuntu`を解決できなかったことと確定した。mixed-architecture data layoutの
一般互換性を証明する試験ではなく、PMIxの値42交換とFenceを実測した結果である。

## final rollback / PASS

candidateをhash照合して削除し、Ubuntu `slurmd`を1134264から1134793へ再起動した。Mac
`/etc/hosts`はbackupから事前SHA
`e8595fbd163b74eb6191e76dbbaf5f7756c362a9a8c72ae63f7d0665a07a5522`へbyte完全復元し、`ubuntu`
entry不在を独立確認した。backup stateは
`/private/tmp/slurm-smd401-pmix6-host-alias-restored-20260924T171349`へ保持した。

最終readbackは次を確認した。

- Ubuntu PMIx v6 plugin不在、production MPI列挙は`none`、`cray_shasta`、`pmi2`。
- `slurmctld` PID 197928、`slurmdbd` PID 189104、Mac `slurmd` PID 41674は不変。
- Ubuntu `slurmd` PID 1134793、3 service active。
- `ubuntu`、`PC-210`ともIDLE、CPUAlloc 0、queue空。
- Ubuntu `slurm.conf`、`slurmd`、`slurmctld`のSHA-256は事前値と一致。
- Mac `slurm.conf`は`70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0`、
  `slurmd`は`a3df64dde33256a7dff621854ff56501e854cc51ffab2ebb6f91ec5a92d94d72`を維持。

この時点でSMD-401のPMIx v6 2-node direct-launch実測はPASSとした。ただしproductionにはUbuntu
PMIx pluginもMacの`ubuntu` aliasも保持していなかったため、名前解決の恒久化を次の試験へ分離した。

## permanent Mac NodeAddr retry Attempt 6 / PASS

追加承認後、system-wide host aliasを使わず、Mac local `slurm.conf`のUbuntu node行をcontrollerと同期した。
`NodeAddr=192.168.10.180`、`NodeHostName=ubuntu2504`とcontroller同等の資源値を設定し、Mac `slurmd`へ
SIGHUPした。PID 41674を維持し、IDLE、CPUAlloc 0、queue空へ戻った。Mac config SHA-256は
`62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157`である。

`/etc/hosts`を変更しないままexact-source Ubuntu pluginを一時配置し、Job 723のUbuntu単独PMIx、
Job 724のx86-64/arm64 2-rank Put/Get/Fence、Job 725の通信後cancel、Job 726の両PID cleanupを全PASSした。
試験後はpluginを撤去しUbuntu `slurmd`をPID 1136933で復旧した。最終的にcontroller/DB PID不変、
Mac PID 41674、両node IDLE、queue空、plugin不在、`/etc/hosts`未変更を独立確認した。

したがってMac側NodeName解決の恒久対策はPASSとして保持する。Ubuntu PMIx v6 pluginの恒久配置は
別のdeployment判断であり、現在のproduction MPI列挙は`none`、`cray_shasta`、`pmi2`である。詳細は
[`SMD-401 NodeAddr hardening`](SMD-401-nodeaddr-hardening.md)を参照する。
