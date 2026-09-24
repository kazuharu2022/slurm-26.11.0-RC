# SMD-401 Mac local NodeAddr hardening

- 日時: 2026-09-24 17:17 JST
- 状態: `PASS / PRODUCTION_CONFIG_SYNC_RETAINED`
- production変更: Mac local `slurm.conf`のUbuntu node定義1行をcontrollerと同期
- daemon signal/restart: Mac `slurmd`へSIGHUP 1回。Ubuntu `slurmd`を一時plugin配置・撤去時に各1回再起動
- Job投入: 723〜726

## 目的

PMIx v6 2-node direct-launchは、一時`/etc/hosts` aliasを追加したJob 719でPASSした。ただしaliasと
Ubuntu PMIx pluginは試験後に撤去しており、現在のproduction状態だけでは同じPMIx direct接続を再現できない。
system-wide `/etc/hosts` aliasを常設せず、Slurm自身の`NodeAddr`設定で接続先を解決できるようにする。

## read-only結果

Mac `slurmd`はlaunchd label `system/org.schedmd.slurmd`、PID 41674でrunningである。plistは
`-f /opt/slurm/26.11.0/etc/slurm.conf -N PC-210`と`SLURM_CONF`を同じfileへ固定している。

Mac側のUbuntu node定義にはaddress情報がない。

```text
NodeName=ubuntu CPUs=8 Boards=1 SocketsPerBoard=8 CoresPerSocket=1 ThreadsPerCore=1 RealMemory=15990
```

Ubuntu controller側のproduction定義は次である。

```text
NodeName=ubuntu NodeAddr=192.168.10.180 NodeHostName=ubuntu2504 CPUs=8 Boards=1 SocketsPerBoard=1 CoresPerSocket=4 ThreadsPerCore=2 RealMemory=64024
```

Ubuntu実hostでは`192.168.10.180/24`が`br0`へ`valid_lft forever`で設定され、controllerの実効
`NodeAddr`も`192.168.10.180`である。一方、Mac `/etc/hosts`は`ubuntu2504`だけを同addressへ対応させ、
Slurm `NodeName=ubuntu`は解決しない。`/etc/hosts`はJob 719試験前のSHA-256
`e8595fbd163b74eb6191e76dbbaf5f7756c362a9a8c72ae63f7d0665a07a5522`へ復元済みである。

同梱PMIx plugin sourceはjob hostlistから`NodeName`を取り、`slurm_conf_get_addr(nodename, ...)`で
接続先を取得する。したがってMacのローカルSlurm設定へcontrollerと同じ`NodeAddr`を持たせるのが
component-localな修正であり、system-wide host aliasより影響範囲が小さい。

## 候補と静的検証

MacのUbuntu node行だけをcontroller側と同一内容へ置換する。PC-210、partition、auth、TLS、GRES、
controller設定は変更しない。

| 対象 | SHA-256 |
|---|---|
| 現行Mac `slurm.conf` | `70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0` |
| 候補Mac `slurm.conf` | `62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157` |
| install script | `6e64770b56917f06a1e4fb4c4a8222e28335421e0c7876e9e8bfc353336b7cfe` |
| rollback script | `bea078e0180ae2f3753a45b7c6ff00000593c37b6003af43b5d578fb6f291cba` |
| reload driver | `8abdbf5e81f1d57a6b1a87e03edfc088bdb4636cdf34940dd36b33c8239cfcf9` |

3 scriptは`/bin/sh -n`、未承認時rc 64、`git diff --check`をPASSした。sandbox内のnon-root
`scontrol ping`はroot-only auth stateを使えずcontroller DOWN/rc 1となったためruntime証明には使わない。
install scriptは管理者実行時に候補configでcontroller UPを確認できない場合、productionを書き換える前に停止する。

## 最終read-only再確認

- Mac production `slurm.conf` SHA-256は
  `70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0`、`/etc/hosts`は
  `e8595fbd163b74eb6191e76dbbaf5f7756c362a9a8c72ae63f7d0665a07a5522`で、いずれも未変更。
- Mac launchdの`system/org.schedmd.slurmd`は`running`、PID 41674、実行configは
  `/opt/slurm/26.11.0/etc/slurm.conf`。
- Ubuntuの`slurmctld`、`slurmdbd`、`slurmd`はすべて`active`。PIDは順に197928、189104、1134793。
- UbuntuのPATH先行CLI `/usr/local/bin/scontrol`へ別世代の`/opt/slurm/lib/slurm`を与えた照会は
  controller DOWNと`Insane message length`を返した。これはversion/library不一致による無効な測定として保持する。
- 稼働daemonと同じ`/usr/local/slurm/26.11.0/bin`および
  `/usr/local/slurm/26.11.0/lib/slurm`で再測定するとcontrollerはUP、PC-210とubuntuはIDLEかつ
  CPUAlloc=0、queueは空だった。`vmtest01`の`idle~`は本変更の対象外。

## 承認済み実行境界

1. Mac production `slurm.conf`をhash照合し、root-only backupを作成して候補1行を適用する。
2. Mac `slurmd`だけへSIGHUPし、launchd、PID、IDLE、queue、production hashを確認する。
3. `/etc/hosts` alias不在のままUbuntu PMIx pluginを一時配置し、Ubuntu `slurmd`だけを再起動する。
4. Ubuntu単独gate、2-node PMIx正常終了、cancel、PID cleanupを再実行する。
5. Ubuntu pluginを撤去してUbuntu `slurmd`を復旧する。
6. runtime PASSならMacのNodeAddr同期を保持する。失敗ならMac configをbyte rollbackして再度SIGHUPする。
7. 両hostのservice、node、queue、config/binary hashを独立確認する。

`slurmctld`、`slurmdbd`、Mac `slurmd` restart、`/etc/hosts`、`mpi.conf`は変更しない。SIGHUPはMac
`slurmd`の設定reloadであり、実装上reconfigure処理を通るためPID/StartTimeの前後値を記録する。

## production適用 / PASS

明示承認後、installerは現行SHA-256と旧node行を照合し、root-only state directory
`/private/tmp/slurm-smd401-nodeaddr-sync-active`へbyte backupと候補を保存した。候補configでcontroller UPを
確認してからproductionへ配置し、次のmarkerを返した。

```text
SMD401_MAC_NODEADDR_SYNC_INSTALL_COMPLETE before_sha256=70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0 after_sha256=62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157 state_dir=/private/tmp/slurm-smd401-nodeaddr-sync-active
```

Mac `slurmd`へSIGHUPを1回送り、launchd PID 41674を維持したまま`SlurmdStartTime`が
`2026-09-24T12:08:25`から`2026-09-24T17:35:18`へ更新され、PC-210がIDLE、CPUAlloc 0、queue空へ
戻った。Mac `slurmd` restart、controller reconfigure、`/etc/hosts`変更は行っていない。

## aliasなしPMIx再試験 / PASS

Ubuntu exact-source PMIx v6 plugin SHA-256
`1c4b8d44eaf8279d24611c52c70e858410e449385a7627bc97b8be6a552668bb`を一時配置し、Ubuntu
`slurmd`だけをPID 1134793から1136437へ再起動した。Mac `/etc/hosts`は事前SHAのまま、default direct
connectionで次の結果を得た。

- Job 723: Ubuntu単独PMIx、rank 0、size 1、値42、Fence PASS。job/stepとも`COMPLETED 0:0`。
- Job 724: Ubuntu x86-64とMac arm64の2 rankが同一namespace `slurm.pmix.724.0`へ参加し、両rankで
  値42のPut/Get/Fence PASS。job/stepとも`COMPLETED 0:0`。
- Job 725: 両rankのFence後にPID 1136758/45003を記録してcancel。job=`CANCELLED by 0`、
  step=`CANCELLED 0:15`、client rc 143。
- Job 726: UbuntuとMacの両PIDが消滅し、ready directoryも削除済みであることを確認。

driver markerは次のとおりである。

```text
SMD401_PMIX6_MULTINODE_COMPLETE single_job=723 success_job=724 cancel_job=725 cleanup_job=726 nodes=ubuntu:x86_64,PC-210:arm64 ranks=2 cancel_rc=143 communication=PMIX_PUT_GET_FENCE_PASS pmix_direct_conn=enabled cancel_cleanup=PASS production_unchanged=PASS
```

## temporary plugin撤去と最終readback / PASS

Ubuntu PMIx v6 pluginをhash照合後に撤去し、Ubuntu `slurmd`を1136437から1136933へ再起動した。
`slurmctld` PID 197928と`slurmdbd` PID 189104は全工程で不変だった。最終readbackは次を確認した。

- Mac `slurm.conf` SHA-256は候補値`62bcea15398de5f373132a1a3ef21c005c184c20f483da076b44eb5af284f157`。
- MacのUbuntu node行は`NodeAddr=192.168.10.180 NodeHostName=ubuntu2504`とcontroller同等の資源値を保持。
- Mac `/etc/hosts` SHA-256は`e8595fbd163b74eb6191e76dbbaf5f7756c362a9a8c72ae63f7d0665a07a5522`で未変更。
- Mac `slurmd`はPID 41674でrunning。Ubuntuの3 serviceはactive、controllerはUP。
- PC-210とubuntuはIDLE、CPUAlloc 0、queue空。
- Ubuntu PMIx v6 pluginは不在で、production MPI列挙は`none`、`cray_shasta`、`pmi2`。

以上により、Mac local Slurm configの恒久`NodeAddr`同期は保持する。Ubuntu PMIx plugin自体の恒久配置は
本変更に含めず、試験前状態へ復旧した。rollback scriptと適用前backupは緊急復旧用に保持する。
