#!/opt/slurm/26.11.0/share/macos-gpu-job/.venv/bin/python

"""SMD-208: compare MLX/Metal float32 matmul with a CPU float64 reference."""

from __future__ import annotations

import math
import os
import platform
import struct
import sys
from dataclasses import dataclass

if os.environ.get("MLX_ENABLE_TF32") != "0":
	print("error=MLX_ENABLE_TF32_must_be_0", file=sys.stderr)
	raise SystemExit(2)

import mlx.core as mx


ELEMENT_ATOL = 5.0e-5
ELEMENT_RTOL = 5.0e-5
MAX_ABS_ERROR_LIMIT = 1.0e-3
MEAN_ABS_ERROR_LIMIT = 2.0e-5
RELATIVE_ERROR_FLOOR = 1.0e-12


@dataclass(frozen=True)
class Case:
	name: str
	m: int
	k: int
	n: int


CASES = (
	Case("rect_k31", 7, 31, 11),
	Case("rect_k64", 13, 64, 9),
	Case("rect_k127", 5, 127, 7),
)


def float32(value: float) -> float:
	"""Round a Python float to IEEE-754 binary32 without NumPy."""

	return struct.unpack("!f", struct.pack("!f", value))[0]


def make_inputs(case: Case) -> tuple[list[list[float]], list[list[float]]]:
	"""Create deterministic, non-dyadic inputs and quantize them to float32."""

	a = [
		[
			float32((((row * 17 + inner * 13) % 97) - 48) / 37.0)
			for inner in range(case.k)
		]
		for row in range(case.m)
	]
	b = [
		[
			float32((((inner * 19 + column * 7) % 89) - 44) / 41.0)
			for column in range(case.n)
		]
		for inner in range(case.k)
	]
	return a, b


def cpu_reference(
	a: list[list[float]], b: list[list[float]], case: Case
) -> list[list[float]]:
	"""Accumulate products of identical float32 inputs using float64 math.fsum."""

	return [
		[
			math.fsum(a[row][inner] * b[inner][column] for inner in range(case.k))
			for column in range(case.n)
		]
		for row in range(case.m)
	]


def gpu_result(
	a: list[list[float]], b: list[list[float]]
) -> list[list[float]]:
	gpu_a = mx.array(a, dtype=mx.float32)
	gpu_b = mx.array(b, dtype=mx.float32)
	result = mx.matmul(gpu_a, gpu_b, stream=mx.gpu)
	mx.eval(result)
	mx.synchronize(mx.gpu)
	return result.tolist()


def evaluate_case(case: Case) -> dict[str, float | int | str]:
	a, b = make_inputs(case)
	reference = cpu_reference(a, b, case)
	observed = gpu_result(a, b)

	max_abs_error = 0.0
	total_abs_error = 0.0
	max_relative_error = 0.0
	max_scaled_error = 0.0
	non_finite = 0
	elements = case.m * case.n

	for row in range(case.m):
		for column in range(case.n):
			expected = reference[row][column]
			actual = float(observed[row][column])
			if not math.isfinite(actual):
				non_finite += 1
				continue
			absolute_error = abs(actual - expected)
			tolerance = ELEMENT_ATOL + ELEMENT_RTOL * abs(expected)
			relative_error = absolute_error / max(
				abs(expected), RELATIVE_ERROR_FLOOR
			)
			scaled_error = absolute_error / tolerance
			max_abs_error = max(max_abs_error, absolute_error)
			total_abs_error += absolute_error
			max_relative_error = max(max_relative_error, relative_error)
			max_scaled_error = max(max_scaled_error, scaled_error)

	mean_abs_error = total_abs_error / elements
	passed = (
		non_finite == 0
		and max_scaled_error <= 1.0
		and max_abs_error <= MAX_ABS_ERROR_LIMIT
		and mean_abs_error <= MEAN_ABS_ERROR_LIMIT
	)
	return {
		"name": case.name,
		"shape": f"{case.m}x{case.k}x{case.n}",
		"elements": elements,
		"max_abs_error": max_abs_error,
		"mean_abs_error": mean_abs_error,
		"max_relative_error": max_relative_error,
		"max_scaled_error": max_scaled_error,
		"non_finite": non_finite,
		"status": "PASS" if passed else "FAIL",
	}


def main() -> int:
	if platform.machine() != "arm64":
		print(f"error=unexpected_machine machine={platform.machine()}", file=sys.stderr)
		return 2
	if not mx.metal.is_available():
		print("error=metal_backend_not_available", file=sys.stderr)
		return 2

	mx.set_default_device(mx.gpu)
	device_info = mx.device_info(mx.gpu)
	device_name = device_info.get("device_name", "UNKNOWN")

	print("smd208_schema=1")
	print(f"machine={platform.machine()}")
	print(f"mlx_version={mx.__version__}")
	print(f"default_device={mx.default_device()}")
	print(f"metal_device_name={device_name}")
	print(f"mlx_enable_tf32={os.environ['MLX_ENABLE_TF32']}")
	print("dtype=float32")
	print("reference=python_math_fsum_float64")
	print("input_quantization=ieee754_binary32_struct")
	print(f"element_atol={ELEMENT_ATOL:.8f}")
	print(f"element_rtol={ELEMENT_RTOL:.8f}")
	print(f"max_abs_error_limit={MAX_ABS_ERROR_LIMIT:.8f}")
	print(f"mean_abs_error_limit={MEAN_ABS_ERROR_LIMIT:.8f}")

	results = [evaluate_case(case) for case in CASES]
	for result in results:
		print(
			"case={name} shape={shape} elements={elements} "
			"max_abs_error={max_abs_error:.9e} "
			"mean_abs_error={mean_abs_error:.9e} "
			"max_relative_error={max_relative_error:.9e} "
			"max_scaled_error={max_scaled_error:.9e} "
			"non_finite={non_finite} status={status}".format(**result)
		)

	overall_elements = sum(int(result["elements"]) for result in results)
	overall_mean_abs_error = sum(
		float(result["mean_abs_error"]) * int(result["elements"])
		for result in results
	) / overall_elements
	overall_max_abs_error = max(float(result["max_abs_error"]) for result in results)
	overall_max_relative_error = max(
		float(result["max_relative_error"]) for result in results
	)
	overall_max_scaled_error = max(
		float(result["max_scaled_error"]) for result in results
	)
	overall_status = "PASS" if all(result["status"] == "PASS" for result in results) else "FAIL"

	print(
		f"overall_elements={overall_elements} "
		f"overall_max_abs_error={overall_max_abs_error:.9e} "
		f"overall_mean_abs_error={overall_mean_abs_error:.9e} "
		f"overall_max_relative_error={overall_max_relative_error:.9e} "
		f"overall_max_scaled_error={overall_max_scaled_error:.9e} "
		f"status={overall_status}"
	)
	if overall_status != "PASS":
		print("SMD208_NUMERICAL_CORRECTNESS_FAIL", file=sys.stderr)
		return 1
	print("SMD208_NUMERICAL_CORRECTNESS_PASS")
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
