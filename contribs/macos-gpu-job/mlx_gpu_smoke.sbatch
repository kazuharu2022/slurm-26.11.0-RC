#!/bin/bash
#SBATCH --job-name=mlx_gpu
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=4G
#SBATCH --time=00:02:00
#SBATCH --output=mlx-gpu-%j.out
#SBATCH --error=mlx-gpu-%j.err
## After registering the Mac GPU as a Slurm GRES, enable this directive:
##SBATCH --gres=gpu:apple:1

set -euo pipefail

readonly JOB_ROOT="${MLX_JOB_ROOT:-/opt/slurm/26.11.0/share/macos-gpu-job}"
readonly PYTHON="${JOB_ROOT}/.venv/bin/python"

if [[ ! -x "${PYTHON}" ]]; then
	echo "MLX uv environment not found: ${PYTHON}" >&2
	exit 2
fi

echo "job_id=${SLURM_JOB_ID:-unknown}"
echo "node=$(hostname)"
echo "python=${PYTHON}"
echo "slurm_job_gpus=${SLURM_JOB_GPUS:-not-configured}"

"${PYTHON}" <<'PY'
import platform
import math
import time

import mlx.core as mx

if not mx.metal.is_available():
    raise SystemExit("Metal backend is not available")

mx.set_default_device(mx.gpu)
mx.random.seed(42)
print(f"machine={platform.machine()}")
print(f"mlx_version={mx.__version__}")
print(f"default_device={mx.default_device()}")
print(f"metal_device={mx.device_info(mx.gpu)}")

n = 4096
a = mx.random.uniform(shape=(n, n), dtype=mx.float16)
b = mx.random.uniform(shape=(n, n), dtype=mx.float16)
mx.eval(a, b)

# Warm up Metal kernel compilation before measuring.
c = mx.matmul(a, b, stream=mx.gpu)
mx.eval(c)
mx.synchronize(mx.gpu)

started = time.perf_counter()
for _ in range(5):
    c = mx.matmul(a, b, stream=mx.gpu)
    mx.eval(c)
mx.synchronize(mx.gpu)
elapsed = time.perf_counter() - started

mean_value = float(mx.mean(c.astype(mx.float32)).item())
if not math.isfinite(mean_value):
    raise SystemExit(f"GPU result is not finite: {mean_value}")
print(f"matrix_shape={n}x{n}")
print("iterations=5")
print(f"elapsed_seconds={elapsed:.6f}")
print(f"mean_value={mean_value:.6e}")
print("gpu_smoke_test=PASS")
PY
