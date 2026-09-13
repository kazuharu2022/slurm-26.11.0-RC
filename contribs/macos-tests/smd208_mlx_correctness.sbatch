#!/bin/bash
#SBATCH --job-name=smd208-correctness
#SBATCH --partition=debug
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=1G
#SBATCH --gres=gpu:apple:1
#SBATCH --time=00:02:00

set -euo pipefail

readonly PYTHON=/opt/slurm/26.11.0/share/macos-gpu-job/.venv/bin/python
readonly PAYLOAD=${1:?SMD-208 payload path is required}
export MLX_ENABLE_TF32=0

if [[ ! -x "${PYTHON}" ]]; then
	echo "MLX uv environment not found: ${PYTHON}" >&2
	exit 2
fi
if [[ ! -r "${PAYLOAD}" ]]; then
	echo "SMD-208 payload is not readable: ${PAYLOAD}" >&2
	exit 2
fi

echo "job_id=${SLURM_JOB_ID:-unknown}"
echo "job_user=${SLURM_JOB_USER:-unknown}"
echo "node=$(hostname)"
echo "python=${PYTHON}"
echo "slurm_job_gpus=${SLURM_JOB_GPUS:-not-configured}"
echo "mlx_enable_tf32=${MLX_ENABLE_TF32}"

exec "${PYTHON}" "${PAYLOAD}"
