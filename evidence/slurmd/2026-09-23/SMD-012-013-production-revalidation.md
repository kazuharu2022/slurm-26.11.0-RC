# SMD-012〜013 production再検証

- 日時: 2026-09-23 JST
- 対象: Apple M5 Max / macOS 26.5.1 / arm64
- worker: `PC-210`、Slurm `26.11.0-0rc1`
- controller/database: `ubuntu2504` / Ubuntu / x86-64
- 最終判定: SMD-012=`PASS`、SMD-013=`PASS`

## SMD-012 local config reconfigure

production `slurm.conf`の`SlurmdLogFile`だけを一時pathへ変更し、`scontrol reconfigure`後に元へ
戻した。両reconfigureは同一PID `60321`で完了した。

```text
run_dir=/tmp/slurm-smd012-20260923T164630
alternate_reconfigure_elapsed_seconds=3
alternate_applied pid=60321 old_start=2026-09-23T16:28:48 new_start=2026-09-23T16:46:32
restore_reconfigure_elapsed_seconds=4
production_restored pid=60321 restored_start=2026-09-23T16:46:38
smoke_job=662
SMD012_ROOT_RUN_COMPLETE
```

configは試験前後でbyte-for-byte一致した。

```text
before    70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0
alternate 32d64dfe447ac34f9220af418427e0272c681d95adab591d3a54c3bea78c919b
restored  70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0
```

後続Job 662とbatchは`COMPLETED 0:0`、stdoutは`PC-210.local`、stderrは空だった。nodeは
`IDLE`、`CPUAlloc=0`、`AllocTRES`空、queue空へ戻った。reconfigure境界で既知のconmgr
interrupt FD 5 `EBADF`を各1回記録したが、再登録と後続jobを阻害しなかった。

## SMD-013 driver更新

2026-09-09のdriverはstaging build固定pathと手動daemon起動を前提としていたため、production binary、
production library、launchd bootout/bootstrap、失敗時のproduction plist自動復旧を使う新driverを追加した。
production config、binary、library、plistは変更せず、破損fixtureは`/private/tmp`の隔離spoolだけに作成する。

```text
contribs/macos-tests/smd013_production_spool_sack_recovery.sh
```

## SMD-013 Attempt 1 — launchd path正規化によるharness停止

run directory:

```text
/private/tmp/slurm-smd013-production-20260923T165618
```

launchdはcandidate plist pathの`/tmp`を`/private/tmp`として読み戻した。Phase A daemon PID 67372、
SACK、node=`IDLE`は正常だったが、driverの文字列完全一致がtimeoutした。cleanupは本番plistを
bootstrapし、PID 69437、node=`IDLE`へ自動復旧した。driverのrun directoryを`/private/tmp`へ固定した。

## スリープによるpreflight停止と回復

認証待ち中の17:09:08にMacがIdle Sleepへ入り、17:15:11から941秒のMaintenance Sleepへ遷移した。
controllerは17:16:38からNOT_RESPONDING、17:21:41にDOWNを記録した。17:59:26の次runは破壊的処理前の
preflightで`node is not IDLE`として停止した。

network、`192.168.10.128:6818`、launchd PIDは生存していたがheartbeatは再開しなかったため、本番plistを
clean bootout/bootstrapした。PID 70389、controllerの`now responding`、`returned to service`、node=`IDLE`
を確認した。再試験は`caffeinate -dimsu`配下で実行した。このfailureと回復は削除せず保持する。

## SMD-013 production通し試験 — PASS

成功run directory:

```text
/private/tmp/slurm-smd013-production-20260923T180422
```

```text
phase_a=PASS pid=70502 job_id=663
phase_b=PASS pid=70609 job_id=664
production_restore=PASS pid=70710 job_id=665
SMD013_PRODUCTION_REVALIDATION_COMPLETE node=IDLE queue=EMPTY artifacts=UNCHANGED launchd=PRODUCTION
```

Phase Aでは破損`cred_state`からの復元warningを記録し、clean stop時に62-byte、mode 0600の正常stateを
保存した。

```text
warning: _cred_context_unpack: failed to restore job state from file
```

Phase Bでは`-c`起動により隔離spoolのvestigial directoryを削除した。

```text
_stepd_cleanup_batch_dirs: Purging vestigial job script .../spool/job99999/slurm_script
```

Phase A/Bともregular fileのstale SACKを新しいsocketへ置換した。最終本番SACKもsocketだった。
Jobs 663〜665と各batchは全て`COMPLETED 0:0`、stdoutは`PC-210.local`、stderrは空だった。

成功runで実行したdriverのSHA-256は
`5477eff25373f651c7dff95a8ff68f053a99c762429081c74b4c46512e04ace6`だった。run後、root logを
読取可能なEvidence copyへ保存する処理と、実行中だけ有効な`caffeinate -w <driver-pid>`をdriver内へ
追加した。この追補はproduction操作や成功判定を変えず、成功runと同じsleep guardを内蔵するものだが、
追補後hash自体でdaemon試験は再実行していない。追補後の保持版SHA-256は
`45342d3bd801fb0a3dd30232b5e763855388e2df26cde78f82a82cf947fee037`で、`sh -n`と`bash -n`を通過した。

試験前後のhashは一致した。

```text
70d5f437c6622b860e3eff7c029dcd713a073bfdf90395f5399c9c95f50d16a0  slurm.conf
a3df64dde33256a7dff621854ff56501e854cc51ffab2ebb6f91ec5a92d94d72  slurmd
b037119a9187a189b6ba3a1efbd2b733f5f62802af6bd51f3ae8f0a3e5765d8c  libslurmfull.dylib
5db42efbc0f476ae54968a397961807a6061eea2d53fb131c12329c6e611ede9  org.schedmd.slurmd.plist
```

最終launchdはproduction plist、programはproduction `slurmd`、PIDは`70710`、PPID 1だった。
production spoolは`cred_state`だけでtest fixtureの漏洩なし、node=`IDLE`、`CPUAlloc=0`、
`AllocTRES`空、queue空、candidate daemonと`caffeinate`の残留なしだった。Ubuntuの`slurmctld`、
`slurmdbd`、`slurmd`は全て`active`で、Ubuntu側readbackも同じnode stateだった。

以上からSMD-012とSMD-013をproduction構成の`PASS`へ昇格する。
