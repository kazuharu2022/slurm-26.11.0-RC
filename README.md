# Slurm Workload Manager

## このフォークについて（Apple Metal GPU対応PoC）

このフォークで加えた修正は、Slurm 26.11.0-0rc1をベースに、Apple
Silicon搭載macOSノードでApple Metal GPUワークロードをSlurmから扱えるように
するための実験的な修正です。主な対象はmacOS上の`slurmd` / `slurmstepd`と
クライアント経路で、コントローラの`slurmctld`および`slurmdbd`はUbuntu上で
動作させています。SchedMD公式のmacOS対応版ではありません。

Apple GPUをGRESとして要求したジョブの排他スケジューリング、解放、accounting、
MLX/Metalによる計算、反復実行などは実機で確認しています。ただし、この検証は
完全ではなく、本フォークをLinux版と同等のproduction-ready実装とは位置付けて
いません。特に次の制約・未検証事項があります。

- macOSにはLinux cgroup相当のCPU・メモリ・デバイス強制隔離がありません。SMD-303では
  `proctrack/cgroup`、`task/cgroup`、`cgroup/v2` device制約の3候補がplugin/context名を
  明示して非0終了し、no-op起動しないことを隔離probeで確認しました。
- CPU bind指定はrequest metadataとしてpayloadへ渡りますが、Linux互換のprocess pinningは
  行いません。SMD-301のnegative testではstrict affinity API不在とbind成功表示0件を確認しました。
- core specializationは現行構成で明示的にignoreされ、CPU frequency要求はstep metadataに
  留まります。core isolationや物理周波数制御は行いません。SMD-305のJobs 680〜682では
  daemon/job/資源状態が整合したまま終了することを確認しました。
- GPU GRESの`File=/dev/null`は台数管理用のplaceholderであり、Metalデバイスを
  Slurm外のプロセスから隔離するものではありません。
- TLSは限定した実運用経路でCPU、direct `srun`、Apple GPU、mixed-node、accounting、
  負例と復旧まで確認し、試験用active artifactのarchive退避・削除と削除後の`tls/none`
  smokeも完了しました。保全archive内の試験鍵は再利用せず、TLSを再有効化する場合は
  新規証明書を発行します。恒久運用設計、clean sourceからの再現、Linux側の完全な
  回帰試験などは未完了です。
- `PASS_STAGING`や個別フェーズの成功は、production構成全体の成功を意味しません。

テスト結果は成功例だけでなく、失敗、復旧、未実施項目も含めて保存しています。

- [macOS移植の修正内容・実測結果・制約](doc/slurm_macos_porting_change_summary.md)
- [61項目のテスト計画・判定・実行履歴](doc/slurmd_macos_unverified_test_list.md)
- [テストごとの記録と生ログ](evidence/slurmd/)
- [公開候補文書のEvidence品質レビュー](evidence/slurmd/2026-09-12/article-quality-review.md)

## リポジトリと再現用snapshot

- 公開フォーク: <https://github.com/kazuharu2022/slurm-26.11.0-RC>
- SchedMD upstream: <https://github.com/SchedMD/slurm>
- 公開branch: `master`
- 記事初版とEvidenceを公開したsnapshot: `1e20bbab8b88a20446ea28b5418ed6a9013a15a7`

2026-09-14に`origin/master`とローカルHEADが上記commitで一致することを
`git ls-remote`と`git rev-parse HEAD`で確認しました。後続commitで結果が変わることを
避ける場合は、branch名ではなくcommitを固定してください。

```bash
git clone https://github.com/kazuharu2022/slurm-26.11.0-RC.git
cd slurm-26.11.0-RC
git checkout 1e20bbab8b88a20446ea28b5418ed6a9013a15a7
git remote add upstream https://github.com/SchedMD/slurm.git
```

> [!NOTE]
> 61項目の検証は、複数日にわたるdirtyな開発treeと段階的に導入したstaging artifactで
> 実施しました。上記commitは記事・Evidenceを含む公開snapshotですが、すべての途中状態を
> clean checkoutから一括再現できたという意味ではありません。clean-source再buildとLinux
> regressionは引き続きMissing Evidenceです。

## macOSで検証したconfigure条件

検証機の`config.status --config`から採取した値です。`PKG_CONFIG_PATH`に重複していた同じ
directoryだけを除き、意味を変えずに読みやすくしています。

前提として、Apple Clangと`make`に加え、次のpathにdependencyが存在していました。

| dependency | 検証時のpath |
|---|---|
| hwloc | `/opt/homebrew/opt/hwloc` |
| json-c | `/opt/homebrew/opt/json-c` |
| libjwt 2.1.3 | `/opt/slurm-deps/libjwt-2.1.3` |
| Autoconf / Automake / glibtoolize / pkg-config | `/opt/homebrew/bin` |

```bash
export CPPFLAGS="-I/opt/slurm-deps/libjwt-2.1.3/include -I/opt/homebrew/opt/hwloc/include"
export LDFLAGS="-L/opt/slurm-deps/libjwt-2.1.3/lib -L/opt/homebrew/opt/hwloc/lib"
export PKG_CONFIG_PATH="/opt/homebrew/opt/json-c/lib/pkgconfig:/opt/homebrew/opt/hwloc/lib/pkgconfig:/opt/slurm-deps/libjwt-2.1.3/lib/pkgconfig"

./configure \
  --prefix=/opt/slurm/26.11.0 \
  --sysconfdir=/opt/slurm/26.11.0/etc \
  --with-jwt=/opt/slurm-deps/libjwt-2.1.3 \
  --with-hwloc=/opt/homebrew/opt/hwloc \
  --with-json=/opt/homebrew/opt/json-c \
  --without-munge \
  --without-readline \
  --disable-cgroupv2 \
  --disable-x11 \
  --disable-sview \
  --disable-slurmrestd

./config.status --config
make -j"$(sysctl -n hw.ncpu)"
```

この構成はMUNGEではなく`auth/slurm` / `cred/slurm`を使います。controllerとworkerで
同じ`slurm.key`が必要ですが、鍵の内容をrepositoryやlogへ保存してはいけません。
`--disable-cgroupv2`はmacOSにLinux cgroupがないためです。CPU affinity、memory/device
enforcement、task-level accountingがLinuxと同等になるオプションではありません。

production prefixを直接上書きする前に、次のように`DESTDIR`へstageして内容とhashを
確認してください。本検証でもproduction変更を伴うphaseはbackup、hash照合、smoke、復旧を
一組にし、単純な`sudo make install`は再現手順にしていません。

```bash
stage_root="$(mktemp -d /tmp/slurm-install-stage.XXXXXX)"
make DESTDIR="$stage_root" install
find "$stage_root/opt/slurm/26.11.0" -type f -print | sort
```

## macOS worker設定の要点

次は検証時の主要値です。controller名、address、CPU数、memory量は自分の環境で実測し、
controller側の`NodeName`定義と一致させてください。これは完全なcluster設定ではなく、
macOS worker固有項目を示す抜粋です。

```ini
ClusterName=cluster
SlurmctldHost=ubuntu2504
AuthType=auth/slurm
CredType=cred/slurm
PluginDir=/opt/slurm/26.11.0/lib/slurm
SlurmUser=slurm
SlurmdUser=root
SlurmdPidFile=/var/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd

ProctrackType=proctrack/pgid
# TaskPluginは未指定。検証buildでのeffective値はtask/none。
JobAcctGatherType=jobacct_gather/none
SelectType=select/cons_tres
GresTypes=gpu

NodeName=PC-210 CPUs=18 Boards=1 SocketsPerBoard=1 CoresPerSocket=18 ThreadsPerCore=1 RealMemory=131072 Gres=gpu:apple:1 NodeAddr=192.168.10.128
PartitionName=debug Nodes=PC-210 Default=YES MaxTime=INFINITE State=UP
```

macOS側の`gres.conf`は次の1行でした。

```ini
NodeName=PC-210 Name=gpu Type=apple File=/dev/null
```

`File=/dev/null`はGPU 1台をSlurmへ報告するplaceholderです。Metal device nodeでも、
Slurm外processやGRESを要求しないjobを遮断するdevice isolationでもありません。

`JobAcctGatherType=jobacct_gather/none`ではjobの状態、経過時間、要求・割当資源は残りますが、
processのCPU、RSS、VM、disk I/O実測値は収集されません。SMD-304のJob 675では実際に
CPU 2.029384秒、RSS 133,600 KiB、read/write各32 MiBを消費しても、終了後のCPU値は0、
RSS/VM/I/O/TRESは空でした。live `sstat AveCPU`の巨大値は未取得sentinelの表示であり、
利用量として扱わないでください。詳細は
[`SMD-304`](evidence/slurmd/2026-09-23/SMD-304.md)を参照してください。

core specializationとCPU frequency制御もLinuxと同等ではありません。`--core-spec=1`は
`AllowSpecResourcesUsage=no`により明示的にignoreされ、`srun --cpu-freq=performance`は
要求metadataをStep 682.0へ残しましたが、Slurmが利用するLinux cpufreq sysfsはmacOSに
存在しません。物理周波数を変更できたという結果ではありません。詳細は
[`SMD-305`](evidence/slurmd/2026-09-23/SMD-305.md)を参照してください。

## `slurmd`起動前のチェック

起動前に次を満たしてください。

1. controllerとworkerで`ClusterName`、port、`AuthType`、`CredType`、`slurm.key`が一致する。
2. job userの**数値UID/GID**を両hostで一致させる。名前だけ同じ状態は不可。
3. controllerから`NodeAddr`または`NodeHostname`が現在のworker IPへ解決し、TCP 6818へ届く。
4. workerからcontrollerのTCP 6817へ届く。
5. `slurm.key`を`slurm:slurm 0600`とし、`/var/spool/slurmd`、`/var/log/slurm`、
   `/var/run/slurm`のowner/modeを確認する。鍵の内容は表示しない。
6. `slurmd -C`と`slurmd -G`を実行し、CPU/memory/GRESの不足や重複を解消する。
7. 既存の手動起動`slurmd`とlaunchd版を同時に動かさない。
8. local `-f`とconfigless `--conf-server`を混在させない。最初はlocal `-f`を推奨する。
9. 初期導入は`tls/none`で開始する。SMD-407では限定TLS runtimeを確認済みだが、
   証明書rotationと恒久運用設計は未完了である。

```bash
prefix=/opt/slurm/26.11.0
export SLURM_CONF="$prefix/etc/slurm.conf"

sudo "$prefix/sbin/slurmd" -C -N PC-210
sudo "$prefix/sbin/slurmd" -G -N PC-210 -f "$SLURM_CONF"
"$prefix/bin/scontrol" ping
"$prefix/bin/scontrol" show node PC-210
```

DHCP環境では、検証中にworker IPが変わり、controllerの古い名前解決結果によって
`DOWN+NOT_RESPONDING`になりました。固定値をREADMEからコピーせず、DHCP reservation、DNS、
`/etc/hosts`、または正本`NodeAddr`のいずれかで一貫させてください。

## launchdで起動する

使用したplistとinstallerは次です。

- `etc/launchd/org.schedmd.slurmd.plist`
- `etc/launchd/install-slurmd-launchdaemon.sh`

plistのservice labelは **`system/org.schedmd.slurmd`** です。
`system/org.schedmd.slurm.slurmd`ではありません。installerは未管理の`slurmd` PIDを検出した
場合に停止します。その場合、PIDを直接killして続行せず、現在のjob、queue、pidfile、process、
service identityを確認してから、SMD-014のtakeover手順を参照してください。
plistは`SLURM_CONF=/opt/slurm/26.11.0/etc/slurm.conf`と
`SLURM_SACK_KEY=/opt/slurm/26.11.0/etc/slurm.key`を明示して起動します。

```bash
/usr/bin/plutil -lint etc/launchd/org.schedmd.slurmd.plist
sudo /bin/zsh etc/launchd/install-slurmd-launchdaemon.sh

sudo /bin/launchctl print system/org.schedmd.slurmd
cat /var/run/slurmd.pid
ps -p "$(cat /var/run/slurmd.pid)" -o pid,ppid,lstart,state,command
```

`launchctl bootout`直後の`bootstrap`は、serviceの非同期除去が終わる前だと
`Bootstrap failed: 5: Input/output error`になることがあります。labelが消え、旧PIDが終了した
ことを確認してから再登録してください。plist fileのpathだけで管理状態を判断せず、必要なら
`launchctl procinfo "$(cat /var/run/slurmd.pid)"`でもservice identityを確認します。

## 起動後の正常性確認

processが存在するだけでは正常起動の証拠になりません。controller上のnode state、allocation、
queue、実job、accountingを確認します。rootのprivate cwdをjob userへ継承しないよう、smoke jobは
`--chdir=/tmp`と明示的なoutput pathを使います。

```bash
prefix=/opt/slurm/26.11.0
export SLURM_CONF="$prefix/etc/slurm.conf"

"$prefix/bin/scontrol" ping
"$prefix/bin/scontrol" show node PC-210
"$prefix/bin/squeue" -h -w PC-210

job_id="$(
  sudo -u testuser -H env SLURM_CONF="$SLURM_CONF" \
    "$prefix/bin/sbatch" --parsable \
    --partition=debug --nodelist=PC-210 \
    --nodes=1 --ntasks=1 --cpus-per-task=1 --mem=64M \
    --time=00:01:00 --chdir=/tmp \
    --output=/tmp/slurm-macos-smoke-%j.out \
    --error=/tmp/slurm-macos-smoke-%j.err \
    --wrap='/bin/hostname'
)"

"$prefix/bin/sacct" -j "$job_id" -n -P \
  --format=JobIDRaw,JobName,User,State,ExitCode,NodeList,ReqTRES,AllocTRES
```

完了条件はjobとbatch stepが`COMPLETED|0:0`、nodeが`IDLE`、`CPUAlloc=0`、
`AllocMem=0`、queue空、対象process残留なしです。

## 運用上の注意

- macOSの`/tmp`は実体が`/private/tmp`です。path比較では物理pathを考慮してください。
- sleep/wake後は`slurmd` PIDが生きていてもcontroller上で`DOWN+NOT_RESPONDING`になる場合が
  あります。長時間検証では`caffeinate`を使い、復帰後はcontroller stateも確認してください。
- `--mem`は今回の構成では予約・accounting値であり、hard memory limitではありません。
- `proctrack/pgid`の外へ`setsid()`でescapeしたprocessは自動回収されません。
- configlessはSMD-404で成功しましたが、Linuxのglobal cgroup/affinity設定をそのままMacへ
  配布できません。採用時はplatform defaultとLinux側regressionを別途確認してください。
- TLS用pluginとcertificateをinactive install後、最初のruntime切替はcontroller pingで停止し、
  両hostを`tls/none`へ復旧しました。最初のDarwin `/dev/fd/N`回避はclient-onlyで
  成功後、daemon gateでFD closeにより再失敗したため、初版production certgenは両hostとも旧版へrollback
  しました。FDに依存しない`/bin/sh -c`再修正版はMac/Linuxの隔離反復後に両hostへ再導入し、installed path
  反復をPASSしました。さらにUbuntuだけを一時`tls/s2n`へ切り替え、Mac直接clientで平文拒否とTLS疎通を
  5/5回確認しました。続くno-job診断ではMac `slurmd`をTLSでcontrollerへ登録し`IDLE`を確認後、両hostを
  `tls/none`へ復旧しました。さらにCPU batch、direct `srun`、Apple GPU、arm64/x86-64 mixed-node、
  全accounting、平文・未信頼CA負例をPASSし、両hostを再び`tls/none`へ復旧しました。証明書rotation、
  inactive artifactと証跡はroot-only archiveへ保全後、active pathから整理しました。最終`tls/none`
  smokeも完了しています。archive内の試験秘密鍵は再利用せず、将来TLSを再有効化する場合は新しい証明書を
  発行してください。
- `contribs/macos-tests/`のdriverはproduction設定の退避・復旧を含む検証harnessです。
  guard用環境変数の意味と対象hostを確認せず、まとめて実行しないでください。

This is the Slurm Workload Manager. Slurm is an open-source cluster
resource management and job scheduling system that strives to be simple,
scalable, portable, fault-tolerant, and interconnect agnostic. Slurm
currently has been tested only under Linux.

As a cluster resource manager, Slurm provides three key functions.
First, it allocates exclusive and/or non-exclusive access to resources
(compute nodes) to users for some duration of time so they can perform
work. Second, it provides a framework for starting, executing, and
monitoring work (normally a parallel job) on the set of allocated nodes.
Finally, it arbitrates conflicting requests for resources by managing a
queue of pending work.

# NOTES FOR GITHUB DEVELOPERS

The official issue tracker for Slurm is at

:   <https://support.schedmd.com/>

We welcome code contributions and patches. Please see
[the contributing guidelines](CONTRIBUTING.md) for further details.

# SOURCE DISTRIBUTION HIERARCHY

The top-level distribution directory contains this README as well as
other high-level documentation files, and the scripts used to configure
and build Slurm (see INSTALL). Subdirectories contain the source-code
for Slurm as well as a test suite and further documentation. A quick
description of the subdirectories of the Slurm distribution follows:

> src/ \[ Slurm source \]
>
> :   Slurm source code is further organized into self explanatory
>     subdirectories such as src/api, src/slurmctld, etc.
>
> doc/ \[ Slurm documentation \]
>
> :   The documentation directory contains some latex, html, and ascii
>     text papers, READMEs, and guides. Manual pages for the Slurm
>     commands and configuration files are also under the doc/
>     directory.
>
> etc/ \[ Slurm configuration \]
>
> :   The etc/ directory contains a sample config file, as well as some
>     scripts useful for running Slurm.
>
> slurm/ \[ Slurm include files \]
>
> :   This directory contains installed include files, such as slurm.h
>     and slurm_errno.h, needed for compiling against the Slurm API.
>
> testsuite/ \[ Slurm test suite \]
>
> :   The testsuite directory contains an extensive collection of tests
>     written for Check, Expect and Pytest.
>
> auxdir/ \[ autotools directory \]
>
> :   Directory for autotools scripts and files used to configure and
>     build Slurm
>
> contribs/ \[ helpful tools outside of Slurm proper \]
>
> :   Directory for anything that is outside of slurm proper such as a
>     different api or such. To have this build you need to do a make
>     contrib/install-contrib.

# COMPILING AND INSTALLING THE DISTRIBUTION

Please see the instructions at

:   <https://slurm.schedmd.com/quickstart_admin.html>

Extensive documentation is available from our home page at

:   <https://slurm.schedmd.com/slurm.html>

# LEGAL

Slurm is provided \"as is\" and with no warranty. This software is
distributed under the GNU General Public License, please see the files
COPYING, DISCLAIMER, and LICENSE.OpenSSL for details.
