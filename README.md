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

- macOSにはLinux cgroup相当のCPU・メモリ・デバイス強制隔離がありません。
- GPU GRESの`File=/dev/null`は台数管理用のplaceholderであり、Metalデバイスを
  Slurm外のプロセスから隔離するものではありません。
- UID/GID不一致時のfail-closed動作、TLSの実運用経路、clean sourceからの再現、
  Linux側の完全な回帰試験などは未完了です。
- `PASS_STAGING`や個別フェーズの成功は、production構成全体の成功を意味しません。

テスト結果は成功例だけでなく、失敗、復旧、未実施項目も含めて保存しています。

- [macOS移植の修正内容・実測結果・制約](doc/slurm_macos_porting_change_summary.md)
- [61項目のテスト計画・判定・実行履歴](doc/slurmd_macos_unverified_test_list.md)
- [テストごとの記録と生ログ](evidence/slurmd/)
- [公開候補文書のEvidence品質レビュー](evidence/slurmd/2026-09-12/article-quality-review.md)

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
