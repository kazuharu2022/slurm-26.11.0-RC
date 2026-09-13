# SMD-405～410 optional integration preflight

- 実施日: 2026-09-12
- 対象: PC-210 / Apple M5 Max / arm64 / macOS
- controller: ubuntu2504 / x86_64
- Slurm: `26.11.0-0rc1`
- 操作: read-only
- production変更、daemon再起動、Job投入: なし

## SMD-405 backup controller failover

状態: `PREREQUISITE_MISSING_BACKUP_CONTROLLER`

有効なcontroller定義は`SlurmctldHost=ubuntu2504`の1件だけで、secondary controllerはない。
primary停止試験を行うとcluster全体のcontrollerが失われ、failover試験にはならないため未実施。

再開には同版・同一state/config・auth keyを持つbackup slurmctld、複数
`SlurmctldHost`定義、primary/backup疎通と安全な復旧手順が必要である。

## SMD-406 IPv6

状態: `PREREQUISITE_MISSING_ROUTABLE_IPV6`

PC-210のen0で確認できたIPv6はscope付きlink-local
`fe80::4dc:6e04:7a5e:16cd%en0`だけだった。`ubuntu2504`の名前解決結果は
IPv4 `192.168.10.180`で、先行確認のUbuntu側interfaceにもroutableなglobal/ULA IPv6はない。
head/worker間で安定して名前解決・routeできるIPv6 addressがないため、6817/6818、登録、Jobを
IPv6で試していない。

再開には両hostの固定global/ULA address、AAAAまたは明示address、route、6817/6818 listen、
forward/reverse name resolutionが必要である。

## SMD-407 TLS plugin

状態: `PREFLIGHT_COMPLETE_PREREQUISITE_MISSING_S2N_BOTH_HOSTS`

installed pluginは`tls_none.so`だけで、arm64 bundleである。configureはs2n 1.5.7以上を
検出できず、`WITH_S2N_TRUE='#'`となっている。`slurm.conf`にもTLS provider設定はなく、
現在は`auth/slurm`と`tls/none`で動作している。

再開にはarm64 s2n-tlsと依存libraryを隔離・再現可能にbuildし、Slurmを再configure/buildして
`tls/s2n`を生成する必要がある。CA/certificate配布、期限切れ・不正証明書のfail-closed、
rotation後の回復を別々に設計する。依存追加とproduction binary更新は明示承認が必要である。

2026-09-12に両host用read-only preflight driverを構築した。以後の設計と実測は
[SMD-407専用Evidence](SMD-407.md)で継続する。

両hostでpreflightを完了し、Mac arm64、Ubuntu x86_64の双方で`tls_s2n.so`未導入を確認した。

## SMD-408 dynamic node

状態: `PREREQUISITE_MISSING_DYNAMIC_CAPACITY_AND_ISOLATED_IDENTITY`

同梱documentationは`SelectType=select/cons_tres`と、static node数より大きい
`MaxNodeCount`をdynamic registrationの前提とする。現在`MaxNodeCount`は未指定のため、defaultは
slurm.conf内の3 static nodeと同数で、追加node capacityがない。

さらに同じPC-210でproduction slurmdとdynamic slurmdを同時起動すると、hostname、6818 port、
PID、spool、SACK identityが衝突する。`-Z`の`--conf`ではNodeNameとPortを指定できない。

再開にはcontrollerの`MaxNodeCount`増加、dynamic nodeを収容するpartition、隔離hostname/network
namespace相当、port/PID/spoolの衝突を避けるtest hostまたはVMが必要である。

## SMD-409 power save / reboot

状態: `PREREQUISITE_MISSING_POWER_CONTROL`

現在は`SuspendTime=INFINITE`で、`SuspendProgram`、`ResumeProgram`、`RebootProgram`がない。
SMD-014でlaunchd RunAtLoadと実機reboot、SMD-015で物理sleep/wakeを確認済みだが、これらは
slurmctldがnodeをpower down/upするpower-save lifecycleではない。

再開にはMacを安全にsleep/shutdownし、Wake-on-LANまたは管理controllerから復帰させる
Suspend/Resume/Reboot program、controller timeout/state設計、物理console recoveryが必要である。

## SMD-410 version upgrade / rollback

状態: `PREREQUISITE_MISSING_DISTINCT_TARGET_VERSION`

`/opt/slurm/26.05/sbin/slurmd`と`/opt/slurm/26.11.0/sbin/slurmd`はいずれも
`slurm 26.11.0-0rc1`のarm64 binaryである。source HEADは
`a77367bb482ab2f626fb5981d1349159e5ae8740`で、worktreeにはmacOS port変更がある。
異なるversionのcandidateがないため、同じ版のpath切替をupgrade/rollback成功とは扱わない。

再開には次RCまたは正式版のclean source、macOS patchの再適用、build hash、state/config互換性、
旧版binary一式とrollback markerが必要である。

## 結論

SMD-405～410はすべて前提不足であり、runtime failureでもPASSでもない。現在のMac workerだけで
安全に追加実行できるP2項目は残っていない。最小の拡張候補はUbuntu2504を同版の第二workerとして
構築し、SMD-402を再開することである。ただしhead-nodeへのdaemon追加とcontroller partition変更を
伴うため、ユーザーの明示承認を必要とする。
