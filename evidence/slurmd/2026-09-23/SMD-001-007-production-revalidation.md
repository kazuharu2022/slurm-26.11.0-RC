# SMD-001〜007 production再検証

- 日時: 2026-09-23 JST
- 対象: Apple M5 Max / macOS 26.5.1 / arm64
- worker: `PC-210`、Slurm `26.11.0-0rc1`
- controller/database: `ubuntu2504` / Ubuntu / x86-64
- 目的: `PASS_STAGING`だったSMD-001〜007を、production binaryとproduction configで再検証する
- 現在の判定: `PASS`

## 実行前状態

Macからcontroller `UP`、`PC-210`は`IDLE`、`CPUAlloc=0`、`AllocTRES`空、queue空を確認した。
launchd、pidfile、processはPID `60321`で一致し、processはroot、PPID 1、production prefixから起動していた。
実効TLSは`tls/none`だった。

production `srun`はSMD-014でSMD-001/002修正版を導入したhashと一致した。

```text
0d5ff8c6ea7d793fe4f33588bf6c890d8e4bc7abe742296f6cbf5e061c0103d9  /opt/slurm/26.11.0/bin/srun
a3df64dde33256a7dff621854ff56501e854cc51ffab2ebb6f91ec5a92d94d72  /opt/slurm/26.11.0/sbin/slurmd
0aca56272a232fc1ba594fef1bcfddeb32e089313331e67f2fcf1eb7331f064e  /opt/slurm/26.11.0/sbin/slurmstepd
b037119a9187a189b6ba3a1efbd2b733f5f62802af6bd51f3ae8f0a3e5765d8c  /opt/slurm/26.11.0/lib/slurm/libslurmfull.dylib
9c7021e4c794fd9ec4e76af0b7cd5c574d1cd058b9ba9c60c849103f0a7577a2  /opt/slurm/26.11.0/etc/slurm.conf
```

## production再検証driver

既存driverの既定staging pathは変更せず、環境変数でproduction pathを明示できるようにした。
PTYは`expect`がlocal PTYを生成し、stdin/stdout、TTY device、`41x89`から`34x100`へのresize、Ctrl-C
status 130、終了後のlocal TTY設定復元を検査する。root driverはqueue/node/artifact/PIDを前後比較し、
失敗時はこのdriverが投入したjobだけをcancelする。SMD-001〜007ではproduction設定とdaemonを変更しない。

cwd修正後の主要driver hash:

```text
a538f19da1549eb6f8b9a6f7d000df6cd57251c80804e44984e8a123277c34b6  smd001_007_production_revalidation.sh
17a9cdb85e9af931fc957eb5887c58a5910bff0127ae664783150196e20248ff  smd002_production_pty_wrapper.sh
aa6e65d38aa1ab71022fbd2a1686fc0a3ba607f93a821f9eb88416bee1458a3d  smd002_production_pty.exp
```

全shell scriptは`sh -n`、Expect scriptは引数gateまでの構文読込、全差分は`git diff --check`を通過した。

## Attempt 1 — harness false negative

run directory:

```text
/tmp/slurm-smd001-007-production-20260923T160851
```

管理者processから`testuser`へ切り替えた後も、`testuser`が探索できないworkspace cwdを継承したため、
Job ID発行前に停止した。

```text
srun: error: getcwd failed: Permission denied
```

Slurm、production config、daemonの失敗ではない。testuserで実行する全client経路とPTY wrapperを
`cd /tmp`後に起動するよう修正した。この失敗runは削除しない。

## Attempt 2 — production NodeAddr不足を再現

run directory:

```text
/tmp/slurm-smd001-007-production-20260923T161121
```

cwd修正後、production `srun`はJob 640を割り当てたが、Mac local production configの
`NodeName=PC-210`に明示的な`NodeAddr`がなく、短縮名からstep送信先を得られず停止した。

```text
srun: error: _fwd_tree_get_addr: can't find address for host PC-210, check slurm.conf
srun: error: Task launch for StepId=640.0 failed on node PC-210: Can't find an address, check slurm.conf
srun: error: Application launch failed: Can't find an address, check slurm.conf
srun: Job step aborted
```

accounting:

```text
JobIDRaw|JobName|User|State|ExitCode|NodeList
640|smd001-production|testuser|FAILED|0:116|PC-210
640.0|smd001-production||CANCELLED|0:116|PC-210
```

これは2026-09-09のSMD-001 staging前に観測し、検証用configへ数値`NodeAddr`を追加して回避したものと
同じproduction config gapである。現在のMac `en0`は`192.168.10.128`、Ubuntu `/etc/hosts`も
`192.168.10.128 pc210 PC-210`であり、Ubuntuからの名前解決は同じaddressを返した。Mac/Ubuntu双方の
production `slurm.conf`では`NodeName=PC-210`行に`NodeAddr`がない。

## Attempt 2後の安全確認

- Job 640はqueueから消滅。
- Mac/Ubuntu双方のreadbackで`PC-210`は`IDLE`、`CPUAlloc=0`、`AllocTRES`空。
- Mac slurmd PIDは`60321`のまま、`SlurmdStartTime=2026-09-23T14:26:38`で不変。
- Mac production config hashは`9c7021e4...a7577a2`のまま。
- Ubuntu production config hashは`56ab879e...eff169f`のまま。
- production artifact、config、daemon、launchdへの変更は行っていない。

## Attempt 2時点の判定と承認境界

fail-fast方針により、SMD-001がproduction構成で失敗した時点でSMD-002〜007へ進んでいない。
SMD-012/013もこのrunでは実行していない。SMD-001〜007の台帳は`PASS_STAGING`を維持する。

推奨修正は、MacとUbuntuのproduction `slurm.conf`の`NodeName=PC-210`行へ
`NodeAddr=192.168.10.128`を追加することである。両configをroot-only backupへ保存し、candidate parseと
前後hashを確認し、controller reconfigure後にnode `IDLE`・queue空を確認する。失敗時は両hostのconfigを
byte-for-byte復元する。このproduction config変更とreconfigureは別の明示承認を得てから行い、その後に
SMD-001〜007を先頭から再実行する。

## production NodeAddr修正

明示承認後、MacとUbuntuのproduction `slurm.conf`をroot-only directoryへbackupし、両方の
`NodeName=PC-210`行へ`NodeAddr=192.168.10.128`を追加した。candidate parse後にcontrollerへ
reconfigureを要求し、両hostから同じ実効NodeAddrを読み戻した。

```text
Mac before  9c7021e4c794fd9ec4e76af0b7cd5c574d1cd058b9ba9c60c849103f0a7577a2
Mac after   70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0
Ubuntu before 56ab879e4ae3a845950e15d2665f33543c5108ecae9b2008ef886b600eff169f
Ubuntu after  1e6c257b82aa82e507eb710a3e37690ffcfd7b402cb2b33fde53ed9bb1651c68
```

backupは次へ保存した。

```text
/opt/slurm/26.11.0/.smd001-nodeaddr-backup-20260923T162844
/usr/local/slurm/26.11.0/.smd001-nodeaddr-backup-20260923T162844
```

Mac slurmdはPID `60321`を維持し、nodeは`IDLE`、queue空だった。Ubuntuの`slurmctld`、
`slurmdbd`、`slurmd`も全て`active`だった。

## PTY harness補正

production再試験中、PTYの機能結果は成功していたが、macOSのtermios `PENDIN` bitを端末設定の
未復元と誤判定した。`PENDIN`はpending inputを示す一時的なkernel stateであるため、この1 bitだけを
比較からmaskし、その他のtermios stateは完全一致、window sizeは`41x89`へ戻ることを引き続き検査した。
単独Job 647でstdin/stdout、TTY、resize、Ctrl-C=`130`、srun rc 0、TTY復元、job/step
`COMPLETED 0:0`を確認した。

最終driver hash:

```text
a538f19da1549eb6f8b9a6f7d000df6cd57251c80804e44984e8a123277c34b6  smd001_007_production_revalidation.sh
8ed973a666ad912aef92d58c87e53e2e1a3ccd26a3b4a0adac9d2d36a32d340e  smd002_production_pty_wrapper.sh
48def98f47baeadf68620a49952660baed6b2efd174d9413ff8f8aaee41bb539  smd002_production_pty.exp
```

## production通し試験 — PASS

成功run directory:

```text
/tmp/slurm-smd001-007-production-20260923T164209
```

Jobs 648〜661をproduction binary、library、config、daemonで実行した。期待した正常終了だけでなく、
exit 1/255、TERM trap、通常cancel、TERM無視後のSIGKILL、TIMEOUT、ENOENT、EACCESも会計状態と
一致した。

```text
648 COMPLETED 0:0   SMD-001 hostname
649 COMPLETED 0:0   SMD-002 PTY
650 COMPLETED 0:0   SMD-003 exit 0
651 FAILED    1:0   SMD-003 exit 1
652 FAILED  255:0   SMD-003 exit 255
653 FAILED   42:0   SMD-004 TERM trap
654 CANCELLED 0:0   SMD-004 normal cancel; batch 0:15
655 CANCELLED 0:0   SMD-004 force kill; batch 0:9
656 CANCELLED 0:0   SMD-005 control; batch 0:15
657 CANCELLED 0:0   SMD-005 process tree; batch 0:15
658 TIMEOUT    0:0  SMD-006; batch FAILED 124:0
659 FAILED     2:0  SMD-007 ENOENT
660 FAILED    13:0  SMD-007 EACCES
661 COMPLETED  0:0  SMD-007 missing chdir fallback
```

SMD-002は`/dev/ttys003`、`41x89→34x100→41x89`、Ctrl-C=`130`、
`SMD002_TTY_RESTORE=PASS`だった。SMD-005はtargetのbatch/child/background/grandchildを全て回収し、
control jobはtarget cancel後もRUNNINGを維持した。SMD-006はbatch/child両PIDを回収した。

試験前後で次のproduction artifact hashは一致した。

```text
0d5ff8c6ea7d793fe4f33588bf6c890d8e4bc7abe742296f6cbf5e061c0103d9  srun
a3df64dde33256a7dff621854ff56501e854cc51ffab2ebb6f91ec5a92d94d72  slurmd
0aca56272a232fc1ba594fef1bcfddeb32e089313331e67f2fcf1eb7331f064e  slurmstepd
b037119a9187a189b6ba3a1efbd2b733f5f62802af6bd51f3ae8f0a3e5765d8c  libslurmfull.dylib
70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0  slurm.conf
```

Mac slurmd PIDは`60321`で不変、node=`IDLE`、`CPUAlloc=0`、`AllocTRES`空、queue空だった。
以上からSMD-001〜007をproduction構成の`PASS`へ昇格する。
