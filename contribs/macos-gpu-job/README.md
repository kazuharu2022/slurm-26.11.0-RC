# macOS Metal GPU job for Slurm

This job uses the open-source Apple MLX framework from a uv-managed Python
3.14.6 environment. The job submits matrix multiplication explicitly to
`mx.gpu` and fails unless the Metal backend is available.

## Install the shared environment

Run as root on PC-210:

```bash
install -d -m 755 /opt/slurm/26.11.0/share/macos-gpu-job
install -m 644 pyproject.toml uv.lock \
  /opt/slurm/26.11.0/share/macos-gpu-job/
install -m 755 mlx_gpu_smoke.sbatch \
  /opt/slurm/26.11.0/share/macos-gpu-job/

export UV_CACHE_DIR=/opt/slurm/26.11.0/var/cache/uv
export UV_PYTHON_INSTALL_DIR=/opt/slurm/26.11.0/python
/Users/REDACTED_USER/.local/bin/uv python install 3.14.6
/Users/REDACTED_USER/.local/bin/uv sync --frozen \
  --project /opt/slurm/26.11.0/share/macos-gpu-job \
  --python 3.14.6
chmod -R a+rX /opt/slurm/26.11.0/share/macos-gpu-job \
  /opt/slurm/26.11.0/python
```

## Submit

Run as the Slurm job user. Submit from the user's writable home directory so
the output and error files can be created there:

```bash
cd /home/testuser
SLURM_CONF=/opt/slurm/26.11.0/etc/slurm.conf \
  /opt/slurm/26.11.0/bin/sbatch \
  /opt/slurm/26.11.0/share/macos-gpu-job/mlx_gpu_smoke.sbatch
```

The output must contain `default_device=Device(gpu, 0)` and
`gpu_smoke_test=PASS`.

## Register the GPU as a schedulable resource

The current cluster configuration does not register a GPU GRES. Until this is
configured, the smoke job uses Metal but Slurm cannot prevent two jobs from
sharing the GPU.

Add `GresTypes=gpu` and `Gres=gpu:apple:1` to the controller's `slurm.conf`:

```text
GresTypes=gpu
NodeName=PC-210 CPUs=18 Boards=1 SocketsPerBoard=1 CoresPerSocket=18 ThreadsPerCore=1 RealMemory=131072 Gres=gpu:apple:1
```

Slurm's special `gres/gpu` plugin rejects a GPU that has no `File`. Metal does
not expose the integrated Apple GPU as a Unix device node, so install the
provided `gres.conf.pc210.example` as a configuration-only placeholder on
PC-210:

```bash
install -m 644 gres.conf.pc210.example \
  /opt/slurm/26.11.0/etc/gres.conf
```

`File=/dev/null` is only a stable placeholder used by Slurm to retain one GPU
record. It is not the Metal device and does not provide device isolation.

Validate the local GRES configuration before starting the daemon:

```bash
/opt/slurm/26.11.0/sbin/slurmd -G \
  -f /opt/slurm/26.11.0/etc/slurm.conf
```

The output must not contain `Ignoring file-less GPU`. After reconfiguring the
controller and restarting slurmd, verify `CfgTRES` and `Gres` with `scontrol
show node PC-210`. Then request the resource on submission:

```bash
cd /home/testuser
SLURM_CONF=/opt/slurm/26.11.0/etc/slurm.conf \
  /opt/slurm/26.11.0/bin/sbatch --gres=gpu:apple:1 \
  /opt/slurm/26.11.0/share/macos-gpu-job/mlx_gpu_smoke.sbatch
```

This lets Slurm serialize allocations, but macOS has no Linux cgroup device
isolation. A process outside Slurm can still access the integrated GPU.
