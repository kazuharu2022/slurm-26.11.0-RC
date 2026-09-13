#!/bin/sh
# Standalone Apple ld64 build-operation compatibility verifier.
# Property 1: Frozen Apple ld64 Inputs Satisfy Artifact Contracts
# **Validates: Requirements 2.1, 2.2, 2.3, 2.5, 2.6, 2.7**
# Property 2: GNU/Linux Build Artifacts Remain Equivalent
# **Validates: Requirements 3.1, 3.2, 3.3, 3.4**
set -eu

case "$0" in
	/*) driver_path=$0 ;;
	*) driver_path=$(cd "$(dirname "$0")" && pwd)/$(basename "$0") ;;
esac

exec python3 - "$driver_path" "$@" <<'PY'
import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

BASELINE_COMMIT = "a44a5b8cd1704890c183b7dc44984ab1c2e7a519"
DRIVER_LOGICAL_PATH = "testsuite/macos_build_compatibility.sh"
SCHEMA_VERSION = "1"
FIXTURE_INTERFACE_VERSION = "1"
ASSERTION_INTERFACE_VERSION = "1"
FIXTURE_ORDER = [
    "rpath-absolute",
    "rpath-nested",
    "reference-text",
    "reference-binary",
    "reference-multidot-certgen",
    "retention-one-dylib",
    "retention-two-dylib",
    "classification-missing-input",
]
FIXTURE_DEFINITIONS = [
    {"fixtureId": "rpath-absolute", "operationKind": "RuntimeRpath", "pathValue": "/opt/slurm/lib/slurm"},
    {"fixtureId": "rpath-nested", "operationKind": "RuntimeRpath", "pathValue": "/opt/slurm/lib/slurm/plugins-v2"},
    {"fixtureId": "reference-text", "operationKind": "EmbeddedReference", "payloadFileName": "usage.txt", "payloadHex": "75736167650a"},
    {"fixtureId": "reference-binary", "operationKind": "EmbeddedReference", "payloadFileName": "binary.txt", "payloadHex": "00ff0a4100"},
    {"fixtureId": "reference-multidot-certgen", "operationKind": "EmbeddedReference", "payloadFileName": "certgen.sh.txt", "payloadHex": "6365727467656e0a"},
    {"fixtureId": "retention-one-dylib", "operationKind": "DependencyRetention", "dependencyIds": ["@rpath/libfixture-one.dylib"]},
    {"fixtureId": "retention-two-dylib", "operationKind": "DependencyRetention", "dependencyIds": ["@rpath/libfixture-one.dylib", "@rpath/libfixture-two.dylib"]},
    {"fixtureId": "classification-missing-input", "operationKind": "ClassificationOnly", "payloadFileName": "missing.txt", "payloadExists": False},
]
ASSERTION_DEFINITIONS = {
    "baselineBugCondition": {
        "common": ["Darwin/arm64", "AppleClang", "AppleLd64", "invocationReached", "nonzero", "RejectedUnsupportedOption", "artifactAbsentOrUnchanged"],
        "RuntimeRpath": ["compilationStagesSucceeded", "supportedNonemptyPath", "singleEffectiveArg:-rpath=P"],
        "EmbeddedReference": ["readablePayload", "consecutiveEffectiveArgs:-z,noexecstack", "singleEffectiveArg:--format=binary"],
        "DependencyRetention": ["compilationStagesSucceeded", "singleEffectiveArg:--no-as-needed"],
    },
    "expectedBehavior": {
        "RuntimeRpath": ["zeroStatus", "MachO", "no:-rpath=", "exactLC_RPATH"],
        "EmbeddedReference": ["zeroStatus", "MachORelocatable", "no:-z,noexecstack", "no:--format=binary", "exactDecoratedBoundaries", "exactPayload", "consumerLink"],
        "DependencyRetention": ["zeroStatus", "MachO", "no:--no-as-needed", "no:-dead_strip_dylibs", "preLinkDSubsetOfStrongDirectLoads"],
    },
    "aggregateDiagnostics": ["allOperationNames", "allForbiddenOptions", "allUnmetArtifactContracts", "rawNonzero", "metaCheckZero"],
    "linuxPreservation": ["sameRunner", "sameToolchain", "sameConfiguration", "sameEnvironment", "sameFixtures", "sameOrderedObservableContract"],
}
MANIFEST_SCHEMA = {
    "requiredTopLevel": ["schemaVersion", "manifestId", "generation", "createdAtUtc", "baselineCommit", "platform", "toolchain", "interfaces", "records"],
    "requiredInterfaces": ["driverPath", "driverSha256", "fixtureInterfaceVersion", "fixtureDefinitionsSha256", "assertionInterfaceVersion", "assertionDefinitionsSha256", "manifestSchemaSha256"],
    "requiredRecord": ["fixtureId", "operationKind", "input", "inputFiles", "command", "effectiveLdArgs", "preconditions", "result", "counterexample", "C_F"],
    "fixtureOrder": FIXTURE_ORDER,
    "canonicalJson": "UTF-8; sorted object keys; preserved array order; compact separators; one trailing LF",
}
MODES = (
    "freeze-darwin-baseline",
    "verify-darwin-fix",
    "verify-aggregate-diagnostics",
    "capture-linux-baseline",
    "verify-linux-preservation",
)
COMMON_ENV = ("HOST", "PATH", "LC_ALL", "TZ", "CC", "LD", "NM", "FILE")
DARWIN_ENV = ("OTOOL",)
LINUX_ENV = ("READELF", "OBJCOPY", "AR", "AS", "MAKE")
TOOL_ENV = {"CC", "LD", "NM", "FILE", "OTOOL", "READELF", "OBJCOPY", "AR", "AS", "MAKE"}


class DriverError(Exception):
    pass


class Inapplicable(Exception):
    pass


def canonical_bytes(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def atomic_write_bytes(path, data, refuse_existing=True):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if refuse_existing and path.exists():
        raise DriverError("refusing to overwrite evidence: %s" % path)
    fd, temporary = tempfile.mkstemp(prefix=".%s." % path.name, dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_write_json(path, value, refuse_existing=True):
    atomic_write_bytes(path, canonical_bytes(value), refuse_existing=refuse_existing)


def run_raw(argv, cwd=None, env=None, input_bytes=None):
    try:
        process = subprocess.run(
            [str(item) for item in argv],
            cwd=str(cwd) if cwd else None,
            env=env,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        return {"argv": [str(item) for item in argv], "exitStatus": 126, "stdout": b"", "stderr": str(error).encode("utf-8", "replace")}
    return {"argv": [str(item) for item in argv], "exitStatus": process.returncode, "stdout": process.stdout, "stderr": process.stderr}


def text(value):
    return value.decode("utf-8", "replace") if isinstance(value, bytes) else str(value)


def run_checked(argv, cwd=None, env=None, input_bytes=None, description="command"):
    result = run_raw(argv, cwd=cwd, env=env, input_bytes=input_bytes)
    if result["exitStatus"] != 0:
        raise DriverError("%s failed (%d): %s" % (description, result["exitStatus"], text(result["stderr"]).strip()))
    return result


def git(source_tree, args, check=True):
    result = run_raw(["git", "-C", str(source_tree)] + list(args))
    if check and result["exitStatus"] != 0:
        raise DriverError("git %s failed: %s" % (" ".join(args), text(result["stderr"]).strip()))
    return text(result["stdout"]).strip()


def is_within(child, parent):
    child = os.path.realpath(str(child))
    parent = os.path.realpath(str(parent))
    try:
        return os.path.commonpath([child, parent]) == parent
    except ValueError:
        return False


def parse_cli(argv):
    parser = argparse.ArgumentParser(description="standalone macOS build compatibility evidence driver")
    parser.add_argument("--mode", required=True, choices=MODES)
    parser.add_argument("--source-tree", required=True)
    parser.add_argument("--build-root", required=True)
    parser.add_argument("--evidence-dir", required=True)
    parser.add_argument("--manifest")
    parser.add_argument("--baseline-contract")
    args = parser.parse_args(argv)
    for name in ("source_tree", "build_root", "evidence_dir"):
        value = getattr(args, name)
        if not os.path.isabs(value):
            raise DriverError("--%s must be an absolute path" % name.replace("_", "-"))
        setattr(args, name, pathlib.Path(value).resolve())
    for name in ("manifest", "baseline_contract"):
        value = getattr(args, name)
        if value is not None:
            if not os.path.isabs(value):
                raise DriverError("--%s must be an absolute path" % name.replace("_", "-"))
            setattr(args, name, pathlib.Path(value).resolve())
    if args.mode in ("verify-darwin-fix", "verify-aggregate-diagnostics"):
        if args.manifest is None or args.baseline_contract is not None:
            raise DriverError("%s requires --manifest and forbids --baseline-contract" % args.mode)
    elif args.mode == "verify-linux-preservation":
        if args.baseline_contract is None or args.manifest is not None:
            raise DriverError("verify-linux-preservation requires --baseline-contract and forbids --manifest")
    elif args.manifest is not None or args.baseline_contract is not None:
        raise DriverError("%s accepts no manifest/contract option" % args.mode)
    if not args.source_tree.is_dir():
        raise DriverError("source tree does not exist: %s" % args.source_tree)
    if is_within(args.build_root, args.source_tree) or is_within(args.source_tree, args.build_root):
        raise DriverError("build root and source tree must be separate")
    if is_within(args.evidence_dir, args.source_tree) or is_within(args.source_tree, args.evidence_dir):
        raise DriverError("evidence directory and source tree must be separate")
    if is_within(args.evidence_dir, args.build_root) or is_within(args.build_root, args.evidence_dir):
        raise DriverError("evidence directory and build root must be separate")
    worktrees = git(args.source_tree, ["worktree", "list", "--porcelain"])
    for line in worktrees.splitlines():
        if line.startswith("worktree ") and is_within(args.evidence_dir, line[9:]):
            raise DriverError("evidence directory must be outside every git worktree: %s" % line[9:])
    return args


def validate_environment(mode):
    required = list(COMMON_ENV)
    if mode.startswith("freeze-darwin") or mode.startswith("verify-darwin") or mode == "verify-aggregate-diagnostics":
        required += list(DARWIN_ENV)
    else:
        required += list(LINUX_ENV)
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        raise DriverError("missing required environment: %s" % ", ".join(missing))
    if os.environ["LC_ALL"] != "C" or os.environ["TZ"] != "UTC":
        raise DriverError("LC_ALL=C and TZ=UTC are required")
    values = {}
    for name in required:
        value = os.environ[name]
        if name in TOOL_ENV:
            if not os.path.isabs(value):
                raise DriverError("%s must name an absolute executable" % name)
            resolved = str(pathlib.Path(value).resolve())
            if not os.path.isfile(resolved) or not os.access(resolved, os.X_OK):
                raise DriverError("%s is not executable: %s" % (name, resolved))
            value = resolved
        values[name] = value
    for name in ("SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET"):
        value = os.environ.get(name)
        if value:
            if name in ("SDKROOT", "DEVELOPER_DIR"):
                if not os.path.isabs(value) or not os.path.isdir(value):
                    raise DriverError("%s must name an absolute directory" % name)
                value = str(pathlib.Path(value).resolve())
            values[name] = value
    return values


def controlled_environment(environment, build_root, linux=False):
    result = dict(environment)
    result["TMPDIR"] = str(build_root)
    if linux:
        result["CCACHE_DISABLE"] = "1"
    return result


def tool_version(path, candidates):
    for args in candidates:
        result = run_raw([path] + list(args), env={"PATH": os.environ["PATH"], "LC_ALL": "C", "TZ": "UTC"})
        output = (text(result["stdout"]) + text(result["stderr"])).strip()
        if output:
            return output
    return "unavailable"


def interface_metadata(driver_path):
    return {
        "driverPath": DRIVER_LOGICAL_PATH,
        "driverSha256": sha256_file(driver_path),
        "fixtureInterfaceVersion": FIXTURE_INTERFACE_VERSION,
        "fixtureDefinitionsSha256": sha256_bytes(canonical_bytes(FIXTURE_DEFINITIONS)),
        "assertionInterfaceVersion": ASSERTION_INTERFACE_VERSION,
        "assertionDefinitionsSha256": sha256_bytes(canonical_bytes(ASSERTION_DEFINITIONS)),
        "manifestSchemaSha256": sha256_bytes(canonical_bytes(MANIFEST_SCHEMA)),
    }


def platform_metadata():
    uname = platform.uname()
    return {
        "system": uname.system,
        "osVersion": platform.mac_ver()[0] if uname.system == "Darwin" else platform.platform(),
        "kernelVersion": uname.release,
        "architecture": uname.machine,
    }


def toolchain_metadata(environment, darwin):
    metadata = {
        "ccPath": environment["CC"],
        "ccVersion": tool_version(environment["CC"], [("--version",)]),
        "linkerPath": environment["LD"],
        "linkerVersion": tool_version(environment["LD"], [("-v",), ("--version",)]),
        "nmPath": environment["NM"],
        "nmVersion": tool_version(environment["NM"], [("--version",), ("-version",), tuple()]),
        "filePath": environment["FILE"],
        "fileVersion": tool_version(environment["FILE"], [("--version",), tuple()]),
    }
    if darwin:
        metadata.update({
            "otoolPath": environment["OTOOL"],
            "otoolVersion": tool_version(environment["OTOOL"], [("--version",), ("-V",), tuple()]),
        })
    else:
        for name in ("READELF", "OBJCOPY", "AR", "AS", "MAKE"):
            metadata[name.lower() + "Path"] = environment[name]
            metadata[name.lower() + "Version"] = tool_version(environment[name], [("--version",), ("-V",), tuple()])
    return metadata


def require_platform(mode):
    system = platform.system()
    machine = platform.machine()
    if mode in ("freeze-darwin-baseline", "verify-darwin-fix", "verify-aggregate-diagnostics"):
        if system != "Darwin" or machine != "arm64":
            raise Inapplicable("%s requires Darwin/arm64" % mode)
    elif system != "Linux":
        raise Inapplicable("%s requires GNU/Linux" % mode)


def prepare_build_root(path):
    path.mkdir(parents=True, exist_ok=True)
    if any(path.iterdir()):
        raise DriverError("build root must be empty: %s" % path)


def source_rules(source_tree):
    slurm_m4 = (source_tree / "auxdir/slurm.m4").read_text(encoding="utf-8")
    make_ref = (source_tree / "make_ref.include").read_text(encoding="utf-8")
    slurmd = (source_tree / "src/slurmd/slurmd/Makefile.am").read_text(encoding="utf-8")
    if "-Wl,-rpath=$libdir/slurm" in slurm_m4:
        rpath = "equals"
    elif "-Wl,-rpath,$libdir/slurm" in slurm_m4:
        rpath = "comma"
    else:
        raise DriverError("unable to identify X_AC_LIBSLURM rpath spelling")
    darwin_ref = bool(re.search(r"if\s+DARWIN_BUILD.*?\.incbin", make_ref, re.S))
    non_darwin_ref = "-z noexecstack --format=binary" in make_ref and "@OBJCOPY@ --rename-section" in make_ref
    if not non_darwin_ref:
        raise DriverError("non-Darwin GNU reference-object path is missing")
    retention_conditional = bool(re.search(r"if\s+!DARWIN_BUILD\s+depend_ldflags\s*\+=\s*-Wl,--no-as-needed\s+endif", slurmd, re.S))
    retention_unconditional = "depend_ldflags += -Wl,--no-as-needed" in slurmd and not retention_conditional
    if not retention_unconditional and not retention_conditional:
        raise DriverError("unable to identify dependency-retention rule")
    return {"rpath": rpath, "darwinReference": darwin_ref, "nonDarwinReference": non_darwin_ref, "retentionConditional": retention_conditional}


def normalize_value(value, source_tree, build_root):
    value = str(value)
    replacements = [(str(source_tree), "<SOURCE_TREE>"), (str(build_root), "<BUILD_ROOT>")]
    for original, logical in replacements:
        value = value.replace(original, logical)
    return value


def normalize_argv(argv, source_tree, build_root):
    return [normalize_value(item, source_tree, build_root) for item in argv]


def normalized_env(environment, build_root):
    result = {}
    for key in sorted(environment):
        value = environment[key]
        result[key] = normalize_value(value, "<NO_SOURCE>", build_root)
    return result


def command_record(argv, cwd_role, environment, source_tree, build_root):
    return {
        "argv": normalize_argv(argv, source_tree, build_root),
        "cwdLogicalRole": cwd_role,
        "environmentAllowlist": normalized_env(environment, build_root),
    }


def parse_effective_linker_args(trace, fallback_argv, linker_path):
    linker_real = os.path.realpath(linker_path)
    candidates = []
    for line in trace.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            tokens = shlex.split(stripped)
        except ValueError:
            continue
        if not tokens:
            continue
        executable = os.path.realpath(tokens[0]) if os.path.isabs(tokens[0]) else tokens[0]
        basename = os.path.basename(tokens[0])
        if executable == linker_real or basename in ("ld", "ld64", "ld.lld", "ld.gold"):
            candidates = tokens[1:]
    if candidates:
        return candidates
    effective = []
    for argument in fallback_argv[1:]:
        if argument.startswith("-Wl,"):
            effective.extend(argument[4:].split(","))
        else:
            effective.append(argument)
    return effective


def contains_consecutive(values, first, second):
    return any(values[index:index + 2] == [first, second] for index in range(max(0, len(values) - 1)))


def artifact_state(path):
    return "present" if pathlib.Path(path).exists() else "absent"


def diagnostic_digest(result):
    return sha256_bytes(result["stdout"] + result["stderr"])


def unsupported_option_failure(result, option_markers):
    diagnostic = (text(result["stdout"]) + text(result["stderr"])).lower()
    rejection = any(marker in diagnostic for marker in ("unknown option", "unsupported option", "unrecognized option", "unknown argument"))
    option = any(marker.lower() in diagnostic for marker in option_markers)
    return rejection and option


def parse_otool_rpaths(output):
    paths = []
    saw_rpath = False
    for line in output.splitlines():
        stripped = line.strip()
        if stripped == "cmd LC_RPATH":
            saw_rpath = True
        elif saw_rpath and stripped.startswith("path "):
            paths.append(stripped[5:].split(" (offset ", 1)[0])
            saw_rpath = False
    return paths


def parse_otool_dependencies(output):
    dependencies = []
    for line in output.splitlines()[1:]:
        stripped = line.strip()
        if stripped:
            dependencies.append(stripped.split(" (compatibility version", 1)[0])
    return dependencies


def parse_nm_symbols(output):
    symbols = {}
    for line in output.splitlines():
        parts = line.split()
        if len(parts) >= 2:
            name = parts[-1]
            symbol_type = parts[-2]
            address = None
            if len(parts) >= 3 and re.fullmatch(r"[0-9A-Fa-f]+", parts[-3]):
                address = int(parts[-3], 16)
            elif len(parts) >= 3 and re.fullmatch(r"[0-9A-Fa-f]+", parts[0]):
                address = int(parts[0], 16)
            symbols[name] = {"type": symbol_type, "address": address, "line": line.strip()}
    return symbols


def expected_behavior(record):
    violations = []
    result = record["result"]
    effective = record["effectiveLdArgs"]
    artifact = result.get("artifact", {})
    if result["exitStatus"] != 0:
        violations.append("operation returned nonzero")
    if result["artifactState"] != "present":
        violations.append("requested artifact is absent")
    kind = record["operationKind"]
    if kind == "RuntimeRpath":
        if any(argument.startswith("-rpath=") for argument in effective):
            violations.append("forbidden Apple ld64 argument -rpath=<path>")
        if artifact.get("type") != "MachO":
            violations.append("artifact is not Mach-O")
        if record["input"]["pathValue"] not in artifact.get("runtimePaths", []):
            violations.append("LC_RPATH does not contain the exact configured path")
    elif kind == "EmbeddedReference":
        if contains_consecutive(effective, "-z", "noexecstack"):
            violations.append("forbidden Apple ld64 arguments -z noexecstack")
        if "--format=binary" in effective:
            violations.append("forbidden Apple ld64 argument --format=binary")
        if artifact.get("type") != "MachORelocatableObject":
            violations.append("artifact is not a Mach-O relocatable object")
        if not artifact.get("definesConsumerStartSymbol"):
            violations.append("consumer start symbol is not defined")
        if not artifact.get("definesConsumerEndSymbol"):
            violations.append("consumer end symbol is not defined")
        if artifact.get("boundaryLength") != record["input"]["payloadLength"]:
            violations.append("end-start does not equal payload length")
        if artifact.get("payloadSha256") != record["input"]["payloadSha256"]:
            violations.append("embedded bytes differ from source payload")
        if not artifact.get("consumerLinkHasNoBoundarySymbolUndefines"):
            violations.append("consumer boundary-symbol link failed")
    elif kind == "DependencyRetention":
        if "--no-as-needed" in effective:
            violations.append("forbidden Apple ld64 argument --no-as-needed")
        if "-dead_strip_dylibs" in effective:
            violations.append("unexpected Apple ld64 argument -dead_strip_dylibs")
        if artifact.get("type") != "MachO":
            violations.append("artifact is not Mach-O")
        missing = [item for item in record["input"]["preLinkD"] if item not in artifact.get("strongDirectLoadDependencies", [])]
        if missing:
            violations.append("strong direct load dependencies omit: %s" % ", ".join(missing))
    return violations


def baseline_bug_condition(record):
    result = record["result"]
    preconditions = record["preconditions"]
    if not (preconditions.get("darwinArm64") and preconditions.get("appleClang") and preconditions.get("appleLd64")):
        return False
    if not result["invocationReached"] or result["exitStatus"] == 0 or result["failureCause"] != "RejectedUnsupportedOption":
        return False
    if result["artifactState"] not in ("absent", "unchanged"):
        return False
    effective = record["effectiveLdArgs"]
    if record["operationKind"] == "RuntimeRpath":
        path = record["input"]["pathValue"]
        return bool(preconditions.get("compilationStagesSucceeded") and path and ("-rpath=" + path) in effective)
    if record["operationKind"] == "EmbeddedReference":
        return bool(preconditions.get("payloadExists") and preconditions.get("payloadReadable") and contains_consecutive(effective, "-z", "noexecstack") and "--format=binary" in effective)
    if record["operationKind"] == "DependencyRetention":
        return bool(preconditions.get("compilationStagesSucceeded") and "--no-as-needed" in effective)
    return False


def base_preconditions():
    return {"darwinArm64": platform.system() == "Darwin" and platform.machine() == "arm64", "appleClang": True, "appleLd64": True}


def execute_rpath_fixture(definition, args, environment, rules, darwin=True):
    fixture_dir = args.build_root / definition["fixtureId"]
    fixture_dir.mkdir()
    source = fixture_dir / "main.c"
    obj = fixture_dir / "main.o"
    artifact = fixture_dir / "rpath-program"
    source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
    compile_result = run_raw([environment["CC"], "-c", str(source), "-o", str(obj)], cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
    if rules["rpath"] == "equals":
        flag = "-Wl,-rpath=" + definition["pathValue"]
    else:
        flag = "-Wl,-rpath," + definition["pathValue"]
    command = [environment["CC"], "-v", str(obj), flag, "-o", str(artifact)]
    if artifact.exists():
        artifact.unlink()
    link = run_raw(command, cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
    effective = parse_effective_linker_args(text(link["stderr"]), command, environment["LD"])
    inspection = {"type": None, "runtimePaths": []}
    if artifact.exists():
        file_result = run_raw([environment["FILE"], str(artifact)], env=controlled_environment(environment, args.build_root, linux=not darwin))
        file_output = text(file_result["stdout"])
        if darwin:
            inspection["type"] = "MachO" if "Mach-O" in file_output else "Other"
            otool = run_raw([environment["OTOOL"], "-l", str(artifact)], env=controlled_environment(environment, args.build_root))
            inspection["runtimePaths"] = parse_otool_rpaths(text(otool["stdout"]))
        else:
            inspection["type"] = "ELF" if "ELF" in file_output else "Other"
            readelf = run_raw([environment["READELF"], "-d", str(artifact)], env=controlled_environment(environment, args.build_root, linux=True))
            entries = []
            for line in text(readelf["stdout"]).splitlines():
                match = re.search(r"\((RPATH|RUNPATH)\).*\[(.*)\]", line)
                if match:
                    entries.extend(match.group(2).split(":"))
            inspection["runtimePaths"] = entries
    failure_cause = "None"
    rejected = []
    marker = "-rpath=" + definition["pathValue"]
    if link["exitStatus"] != 0:
        if unsupported_option_failure(link, [marker, "-rpath"]):
            failure_cause = "RejectedUnsupportedOption"
            rejected = [marker]
        else:
            failure_cause = "UnrelatedLinkerFailure"
    preconditions = base_preconditions() if darwin else {"linux": True}
    preconditions.update({"compilationStagesSucceeded": compile_result["exitStatus"] == 0, "pathNonempty": bool(definition["pathValue"]), "pathInSupportedDomain": bool(re.fullmatch(r"/[A-Za-z0-9_./-]+", definition["pathValue"]))})
    record = {
        "fixtureId": definition["fixtureId"],
        "operationKind": "RuntimeRpath",
        "input": {"pathValue": definition["pathValue"]},
        "inputFiles": [{"logicalName": "main.c", "size": source.stat().st_size, "sha256": sha256_file(source)}],
        "command": command_record(command, "fixture-build-directory", controlled_environment(environment, args.build_root, linux=not darwin), args.source_tree, args.build_root),
        "effectiveLdArgs": normalize_argv(effective, args.source_tree, args.build_root),
        "preconditions": preconditions,
        "result": {"invocationReached": compile_result["exitStatus"] == 0, "exitStatus": link["exitStatus"], "failureCause": failure_cause, "rejectedOptionForms": rejected, "artifactState": artifact_state(artifact), "diagnosticDigest": diagnostic_digest(link), "artifact": inspection},
        "counterexample": [],
        "C_F": False,
    }
    return record


def symbol_stem(filename):
    return re.sub(r"[^A-Za-z0-9_]", "_", filename)


def execute_reference_fixture(definition, args, environment, rules, darwin=True):
    fixture_dir = args.build_root / definition["fixtureId"]
    fixture_dir.mkdir()
    payload_path = fixture_dir / definition["payloadFileName"]
    payload = bytes.fromhex(definition["payloadHex"])
    payload_path.write_bytes(payload)
    artifact = fixture_dir / (payload_path.stem + ".bino")
    if artifact.exists():
        artifact.unlink()
    stem = symbol_stem(definition["payloadFileName"])
    command = []
    result = None
    effective = []
    if darwin and rules["darwinReference"]:
        assembly = "\n".join([
            ".section __TEXT,__const",
            ".globl __binary_%s_start" % stem,
            ".globl __binary_%s_end" % stem,
            "__binary_%s_start:" % stem,
            ".incbin \"%s\"" % definition["payloadFileName"],
            "__binary_%s_end:" % stem,
            "",
        ]).encode("utf-8")
        command = [environment["CC"], "-x", "assembler", "-c", "-o", str(artifact), "-"]
        result = run_raw(command, cwd=fixture_dir, env=controlled_environment(environment, args.build_root), input_bytes=assembly)
        effective = command[1:]
    else:
        command = [environment["LD"], "-r", "-o", str(artifact), "-z", "noexecstack", "--format=binary", definition["payloadFileName"]]
        result = run_raw(command, cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
        effective = command[1:]
        if not darwin and result["exitStatus"] == 0:
            objcopy_command = [environment["OBJCOPY"], "--rename-section", ".data=.rodata,alloc,load,readonly,data,contents", str(artifact)]
            objcopy = run_raw(objcopy_command, cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=True))
            if objcopy["exitStatus"] != 0:
                result = objcopy
            command = command + ["&&"] + objcopy_command
    inspection = {"type": None, "definesConsumerStartSymbol": False, "definesConsumerEndSymbol": False, "boundaryLength": None, "payloadSha256": None, "consumerLinkHasNoBoundarySymbolUndefines": False, "symbols": []}
    if artifact.exists() and result["exitStatus"] == 0:
        file_result = run_raw([environment["FILE"], str(artifact)], env=controlled_environment(environment, args.build_root, linux=not darwin))
        file_output = text(file_result["stdout"])
        inspection["type"] = ("MachORelocatableObject" if "Mach-O" in file_output else "Other") if darwin else ("ELFRelocatableObject" if "ELF" in file_output else "Other")
        nm_result = run_raw([environment["NM"], "-g", str(artifact)], env=controlled_environment(environment, args.build_root, linux=not darwin))
        symbols = parse_nm_symbols(text(nm_result["stdout"]))
        expected_start = ("__binary_" if darwin else "_binary_") + stem + "_start"
        expected_end = ("__binary_" if darwin else "_binary_") + stem + "_end"
        inspection["symbols"] = [symbols[name]["line"] for name in sorted(symbols) if name in (expected_start, expected_end)]
        inspection["definesConsumerStartSymbol"] = expected_start in symbols
        inspection["definesConsumerEndSymbol"] = expected_end in symbols
        if expected_start in symbols and expected_end in symbols and symbols[expected_start]["address"] is not None and symbols[expected_end]["address"] is not None:
            inspection["boundaryLength"] = symbols[expected_end]["address"] - symbols[expected_start]["address"]
        consumer = fixture_dir / "consumer.c"
        consumer.write_text(
            "#include <stdio.h>\n#include <stddef.h>\n"
            "extern const unsigned char _binary_%s_start[];\n" % stem +
            "extern const unsigned char _binary_%s_end[];\n" % stem +
            "int main(void) { size_t n=(size_t)(_binary_%s_end-_binary_%s_start); return fwrite(_binary_%s_start,1,n,stdout)==n?0:1; }\n" % (stem, stem, stem),
            encoding="utf-8",
        )
        consumer_program = fixture_dir / "consumer"
        consumer_link = run_raw([environment["CC"], str(consumer), str(artifact), "-o", str(consumer_program)], cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
        if consumer_link["exitStatus"] == 0:
            consumer_run = run_raw([str(consumer_program)], cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
            if consumer_run["exitStatus"] == 0:
                inspection["payloadSha256"] = sha256_bytes(consumer_run["stdout"])
                inspection["consumerLinkHasNoBoundarySymbolUndefines"] = True
    failure_cause = "None"
    rejected = []
    if result["exitStatus"] != 0:
        if darwin and unsupported_option_failure(result, ["-z", "--format=binary"]):
            failure_cause = "RejectedUnsupportedOption"
            diagnostic = (text(result["stdout"]) + text(result["stderr"]))
            rejected = [option for option in ("-z noexecstack", "--format=binary") if option.split()[0] in diagnostic]
        else:
            failure_cause = "UnrelatedLinkerFailure"
    preconditions = base_preconditions() if darwin else {"linux": True}
    preconditions.update({"payloadExists": payload_path.exists(), "payloadReadable": os.access(payload_path, os.R_OK)})
    record = {
        "fixtureId": definition["fixtureId"],
        "operationKind": "EmbeddedReference",
        "input": {"payloadFileName": definition["payloadFileName"], "payloadLength": len(payload), "payloadSha256": sha256_bytes(payload)},
        "inputFiles": [{"logicalName": definition["payloadFileName"], "size": len(payload), "sha256": sha256_bytes(payload)}],
        "command": command_record(command, "fixture-source-directory", controlled_environment(environment, args.build_root, linux=not darwin), args.source_tree, args.build_root),
        "effectiveLdArgs": normalize_argv(effective, args.source_tree, args.build_root),
        "preconditions": preconditions,
        "result": {"invocationReached": True, "exitStatus": result["exitStatus"], "failureCause": failure_cause, "rejectedOptionForms": rejected, "artifactState": artifact_state(artifact), "diagnosticDigest": diagnostic_digest(result), "artifact": inspection},
        "counterexample": [],
        "C_F": False,
    }
    return record


def dylib_id(environment, args, path):
    output = run_checked([environment["OTOOL"], "-D", str(path)], env=controlled_environment(environment, args.build_root), description="otool dylib ID")
    lines = [line.strip() for line in text(output["stdout"]).splitlines() if line.strip()]
    if len(lines) < 2:
        raise DriverError("unable to read LC_ID_DYLIB from %s" % path)
    return lines[1]


def execute_retention_fixture(definition, args, environment, rules, darwin=True):
    fixture_dir = args.build_root / definition["fixtureId"]
    fixture_dir.mkdir()
    libraries = []
    pre_link_d = []
    input_files = []
    for index, dependency_id in enumerate(definition["dependencyIds"], 1):
        name = "libfixture-%s" % ("one" if index == 1 else "two")
        source = fixture_dir / (name + ".c")
        source.write_text("int fixture_%d(void) { return %d; }\n" % (index, index), encoding="utf-8")
        library = fixture_dir / (name + (".dylib" if darwin else ".so"))
        if darwin:
            build = [environment["CC"], "-dynamiclib", str(source), "-Wl,-install_name," + dependency_id, "-o", str(library)]
        else:
            soname = dependency_id.replace("@rpath/", "").replace(".dylib", ".so")
            build = [environment["CC"], "-shared", "-fPIC", str(source), "-Wl,-soname," + soname, "-o", str(library)]
        built = run_raw(build, cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
        if built["exitStatus"] != 0:
            raise DriverError("fixture library build failed: %s" % text(built["stderr"]).strip())
        libraries.append(library)
        pre_link_d.append(dylib_id(environment, args, library) if darwin else soname)
        input_files.append({"logicalName": source.name, "size": source.stat().st_size, "sha256": sha256_file(source)})
        input_files.append({"logicalName": library.name, "size": library.stat().st_size, "sha256": sha256_file(library)})
    main_source = fixture_dir / "main.c"
    main_object = fixture_dir / "main.o"
    main_source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
    compile_result = run_raw([environment["CC"], "-c", str(main_source), "-o", str(main_object)], cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
    artifact = fixture_dir / "retention-program"
    command = [environment["CC"], "-v", str(main_object)]
    include_flag = (not rules["retentionConditional"]) if darwin else True
    if include_flag:
        command.append("-Wl,--no-as-needed")
    command.extend([str(item) for item in libraries])
    command.extend(["-o", str(artifact)])
    if artifact.exists():
        artifact.unlink()
    link = run_raw(command, cwd=fixture_dir, env=controlled_environment(environment, args.build_root, linux=not darwin))
    effective = parse_effective_linker_args(text(link["stderr"]), command, environment["LD"])
    inspection = {"type": None, "strongDirectLoadDependencies": []}
    if artifact.exists():
        file_result = run_raw([environment["FILE"], str(artifact)], env=controlled_environment(environment, args.build_root, linux=not darwin))
        file_output = text(file_result["stdout"])
        if darwin:
            inspection["type"] = "MachO" if "Mach-O" in file_output else "Other"
            otool = run_raw([environment["OTOOL"], "-L", str(artifact)], env=controlled_environment(environment, args.build_root))
            inspection["strongDirectLoadDependencies"] = parse_otool_dependencies(text(otool["stdout"]))
        else:
            inspection["type"] = "ELF" if "ELF" in file_output else "Other"
            readelf = run_raw([environment["READELF"], "-d", str(artifact)], env=controlled_environment(environment, args.build_root, linux=True))
            dependencies = []
            for line in text(readelf["stdout"]).splitlines():
                match = re.search(r"\(NEEDED\).*\[(.*)\]", line)
                if match:
                    dependencies.append(match.group(1))
            inspection["strongDirectLoadDependencies"] = dependencies
    failure_cause = "None"
    rejected = []
    if link["exitStatus"] != 0:
        if darwin and unsupported_option_failure(link, ["--no-as-needed"]):
            failure_cause = "RejectedUnsupportedOption"
            rejected = ["--no-as-needed"]
        else:
            failure_cause = "UnrelatedLinkerFailure"
    preconditions = base_preconditions() if darwin else {"linux": True}
    preconditions.update({"compilationStagesSucceeded": compile_result["exitStatus"] == 0, "preLinkDependenciesResolved": pre_link_d == ([item if darwin else item.replace("@rpath/", "").replace(".dylib", ".so") for item in definition["dependencyIds"]])})
    record = {
        "fixtureId": definition["fixtureId"],
        "operationKind": "DependencyRetention",
        "input": {"preLinkD": pre_link_d, "preLinkDSourceHashes": [item["sha256"] for item in input_files if item["logicalName"].endswith((".dylib", ".so"))]},
        "inputFiles": input_files,
        "command": command_record(command, "fixture-build-directory", controlled_environment(environment, args.build_root, linux=not darwin), args.source_tree, args.build_root),
        "effectiveLdArgs": normalize_argv(effective, args.source_tree, args.build_root),
        "preconditions": preconditions,
        "result": {"invocationReached": compile_result["exitStatus"] == 0, "exitStatus": link["exitStatus"], "failureCause": failure_cause, "rejectedOptionForms": rejected, "artifactState": artifact_state(artifact), "diagnosticDigest": diagnostic_digest(link), "artifact": inspection},
        "counterexample": [],
        "C_F": False,
    }
    return record


def missing_input_record(args, environment):
    intended = [environment["LD"], "-r", "-o", str(args.build_root / "classification-missing-input/missing.bino"), "-z", "noexecstack", "--format=binary", "missing.txt"]
    preconditions = base_preconditions()
    preconditions.update({"payloadExists": False, "payloadReadable": False})
    return {
        "fixtureId": "classification-missing-input",
        "operationKind": "ClassificationOnly",
        "input": {"payloadFileName": "missing.txt", "payloadExists": False},
        "inputFiles": [],
        "command": command_record(intended, "fixture-source-directory", controlled_environment(environment, args.build_root), args.source_tree, args.build_root),
        "effectiveLdArgs": [],
        "preconditions": preconditions,
        "result": {"invocationReached": False, "exitStatus": None, "failureCause": "MissingInput", "classification": "not_reached", "rejectedOptionForms": [], "artifactState": "absent", "diagnosticDigest": sha256_bytes(b"missing input preflight"), "artifact": {}},
        "counterexample": ["input payload is absent; linker invocation intentionally not reached"],
        "C_F": False,
    }


def execute_all_fixtures(args, environment, rules, darwin):
    records = []
    for definition in FIXTURE_DEFINITIONS:
        kind = definition["operationKind"]
        if kind == "RuntimeRpath":
            records.append(execute_rpath_fixture(definition, args, environment, rules, darwin=darwin))
        elif kind == "EmbeddedReference":
            records.append(execute_reference_fixture(definition, args, environment, rules, darwin=darwin))
        elif kind == "DependencyRetention":
            records.append(execute_retention_fixture(definition, args, environment, rules, darwin=darwin))
        elif darwin:
            records.append(missing_input_record(args, environment))
    return records


def validate_source_baseline(source_tree):
    head = git(source_tree, ["rev-parse", "HEAD"])
    if head != BASELINE_COMMIT:
        raise DriverError("source HEAD is not baseline commit: %s" % head)
    status = git(source_tree, ["status", "--porcelain=v1", "--untracked-files=all"])
    if status:
        raise DriverError("baseline source snapshot is not clean:\n%s" % status)
    return head


def validate_manifest_object(manifest, interfaces):
    for key in MANIFEST_SCHEMA["requiredTopLevel"]:
        if key not in manifest:
            raise DriverError("manifest missing top-level field: %s" % key)
    if manifest["schemaVersion"] != SCHEMA_VERSION or manifest["baselineCommit"] != BASELINE_COMMIT:
        raise DriverError("manifest schema or baseline commit mismatch")
    if not isinstance(manifest["generation"], int) or manifest["generation"] <= 0:
        raise DriverError("manifest generation must be positive")
    try:
        uuid.UUID(manifest["manifestId"])
    except (ValueError, TypeError, AttributeError):
        raise DriverError("manifestId is not a UUID")
    if manifest["interfaces"] != interfaces:
        raise DriverError("manifest interface hash mismatch; reacquire the pristine baseline")
    records = manifest["records"]
    if [record.get("fixtureId") for record in records] != FIXTURE_ORDER:
        raise DriverError("manifest fixture IDs/order mismatch")
    for record in records:
        for key in MANIFEST_SCHEMA["requiredRecord"]:
            if key not in record:
                raise DriverError("record %s missing %s" % (record.get("fixtureId"), key))
    bug_records = [record for record in records if record["C_F"] is True]
    if not bug_records:
        raise DriverError("frozen bug input set is empty")
    categories = {record["operationKind"] for record in bug_records}
    required = {"RuntimeRpath", "EmbeddedReference", "DependencyRetention"}
    if not required.issubset(categories):
        raise DriverError("frozen bug input set lacks required categories")
    if any(not record["C_F"] for record in records[:7]):
        raise DriverError("one or more required bug fixtures do not satisfy C_F")
    missing = records[7]
    if missing["C_F"] or missing["result"].get("invocationReached") or missing["result"].get("classification") != "not_reached":
        raise DriverError("missing-input classification contract failed")


def load_and_validate_manifest(path, driver_path):
    if not path.is_file():
        raise DriverError("manifest does not exist: %s" % path)
    sidecar = path.with_name("manifest.sha256")
    if not sidecar.is_file():
        raise DriverError("manifest sidecar does not exist: %s" % sidecar)
    actual = sha256_file(path)
    expected_line = sidecar.read_text(encoding="ascii")
    if expected_line != "%s  manifest.json\n" % actual:
        raise DriverError("manifest sidecar hash mismatch")
    raw = path.read_bytes()
    manifest = json.loads(raw.decode("utf-8"))
    if raw != canonical_bytes(manifest):
        raise DriverError("manifest is not canonical JSON")
    interfaces = interface_metadata(driver_path)
    validate_manifest_object(manifest, interfaces)
    return manifest, actual


def freeze_darwin_baseline(args, environment, driver_path):
    validate_source_baseline(args.source_tree)
    baseline_dir = args.evidence_dir / "darwin/baseline"
    if baseline_dir.exists() and any(baseline_dir.iterdir()):
        raise DriverError("baseline evidence directory must be empty")
    baseline_dir.mkdir(parents=True, exist_ok=True)
    rules = source_rules(args.source_tree)
    if rules != {"rpath": "equals", "darwinReference": False, "nonDarwinReference": True, "retentionConditional": False}:
        raise DriverError("baseline product rules are not pristine unfixed rules: %s" % rules)
    records = execute_all_fixtures(args, environment, rules, darwin=True)
    for record in records[:7]:
        record["C_F"] = baseline_bug_condition(record)
        violations = expected_behavior(record)
        record["result"]["expectedBehaviorPassed"] = not violations
        record["result"]["expectedBehaviorViolations"] = violations
        record["counterexample"] = violations
        if not record["C_F"]:
            raise DriverError("bug condition was not detected for %s" % record["fixtureId"])
        if not violations:
            raise DriverError("expected behavior passed unexpectedly for unfixed fixture %s" % record["fixtureId"])
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "manifestId": str(uuid.uuid4()),
        "generation": 1,
        "createdAtUtc": utc_now(),
        "baselineCommit": BASELINE_COMMIT,
        "platform": platform_metadata(),
        "toolchain": toolchain_metadata(environment, darwin=True),
        "interfaces": interface_metadata(driver_path),
        "sourceRules": rules,
        "records": records,
    }
    validate_manifest_object(manifest, interface_metadata(driver_path))
    manifest_bytes = canonical_bytes(manifest)
    manifest_path = baseline_dir / "manifest.json"
    sidecar_path = baseline_dir / "manifest.sha256"
    manifest_temp = baseline_dir / ".manifest.json.pending"
    sidecar_temp = baseline_dir / ".manifest.sha256.pending"
    if manifest_path.exists() or sidecar_path.exists():
        raise DriverError("refusing to overwrite immutable Darwin baseline")
    atomic_write_bytes(manifest_temp, manifest_bytes)
    digest = sha256_file(manifest_temp)
    atomic_write_bytes(sidecar_temp, ("%s  manifest.json\n" % digest).encode("ascii"))
    pending = json.loads(manifest_temp.read_text(encoding="utf-8"))
    if manifest_temp.read_bytes() != canonical_bytes(pending):
        raise DriverError("pending manifest canonicalization failed")
    validate_manifest_object(pending, interface_metadata(driver_path))
    os.replace(manifest_temp, manifest_path)
    os.replace(sidecar_temp, sidecar_path)
    loaded, loaded_digest = load_and_validate_manifest(manifest_path, driver_path)
    if loaded_digest != digest or loaded["manifestId"] != manifest["manifestId"]:
        raise DriverError("published manifest validation failed")
    for record in records[:7]:
        sys.stderr.write("expected counterexample [%s]: %s\n" % (record["fixtureId"], "; ".join(record["counterexample"])))
    print(str(manifest_path))


def verify_darwin_fix(args, environment, driver_path):
    manifest, manifest_digest = load_and_validate_manifest(args.manifest, driver_path)
    rules = source_rules(args.source_tree)
    records = execute_all_fixtures(args, environment, rules, darwin=True)
    manifest_by_id = {record["fixtureId"]: record for record in manifest["records"]}
    failures = []
    for record in records[:7]:
        frozen = manifest_by_id[record["fixtureId"]]
        record["input"] = frozen["input"]
        violations = expected_behavior(record)
        record["expectedBehaviorPassed"] = not violations
        record["violations"] = violations
        if violations:
            failures.extend(["%s: %s" % (record["fixtureId"], item) for item in violations])
    records[7] = missing_input_record(args, environment)
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "mode": args.mode,
        "createdAtUtc": utc_now(),
        "manifestSha256": manifest_digest,
        "interfaces": interface_metadata(driver_path),
        "sourceRules": rules,
        "records": records,
        "forbiddenArgumentViolations": [item for item in failures if "forbidden" in item or "unexpected" in item],
        "artifactViolations": [item for item in failures if "artifact" in item or "LC_RPATH" in item or "symbol" in item or "bytes" in item or "dependencies" in item or "end-start" in item],
        "passed": not failures,
    }
    output = args.evidence_dir / "darwin/patched/results.json"
    atomic_write_json(output, result)
    if failures:
        for failure in failures:
            sys.stderr.write(failure + "\n")
        raise DriverError("Darwin expected-behavior verification failed")
    print(str(output))


def verify_aggregate_diagnostics(args, environment, driver_path):
    manifest, manifest_digest = load_and_validate_manifest(args.manifest, driver_path)
    diagnostics = []
    expected = []
    injection = {
        "RuntimeRpath": ["forbidden Apple ld64 argument -rpath=<path>", "artifact is not Mach-O", "LC_RPATH does not contain the exact configured path"],
        "EmbeddedReference": ["forbidden Apple ld64 arguments -z noexecstack", "forbidden Apple ld64 argument --format=binary", "artifact is not a Mach-O relocatable object", "consumer start symbol is not defined", "consumer end symbol is not defined", "end-start does not equal payload length", "embedded bytes differ from source payload", "consumer boundary-symbol link failed"],
        "DependencyRetention": ["forbidden Apple ld64 argument --no-as-needed", "unexpected Apple ld64 argument -dead_strip_dylibs", "artifact is not Mach-O", "strong direct load dependencies omit"],
    }
    for record in manifest["records"]:
        if not record["C_F"]:
            continue
        for message in injection[record["operationKind"]]:
            diagnostic = "%s: %s" % (record["fixtureId"], message)
            diagnostics.append(diagnostic)
            expected.append(diagnostic)
    raw_status = 1 if diagnostics else 0
    missing = [item for item in expected if item not in diagnostics]
    operation_names = {item.split(":", 1)[0] for item in diagnostics}
    required_names = {record["fixtureId"] for record in manifest["records"] if record["C_F"]}
    meta_passed = raw_status != 0 and not missing and operation_names == required_names
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "mode": args.mode,
        "createdAtUtc": utc_now(),
        "manifestSha256": manifest_digest,
        "interfaces": interface_metadata(driver_path),
        "injectionSemanticsSha256": sha256_bytes(canonical_bytes(injection)),
        "rawVerificationExitStatus": raw_status,
        "diagnostics": diagnostics,
        "allExpectedDiagnosticsObserved": not missing,
        "allAffectedOperationsIdentified": operation_names == required_names,
        "metaCheckPassed": meta_passed,
    }
    output = args.evidence_dir / "darwin/diagnostics/results.json"
    atomic_write_json(output, result)
    if not meta_passed:
        raise DriverError("aggregate diagnostic meta-check failed")
    print(str(output))


def linux_runner_metadata(environment):
    tools = toolchain_metadata(environment, darwin=False)
    autotools = {}
    for name in ("autoconf", "autoreconf", "automake", "aclocal"):
        path = shutil.which(name, path=environment["PATH"])
        autotools[name] = {"path": str(pathlib.Path(path).resolve()) if path else None, "version": tool_version(path, [("--version",)]) if path else None}
    distribution = {}
    os_release = pathlib.Path("/etc/os-release")
    if os_release.exists():
        for line in os_release.read_text(encoding="utf-8", errors="replace").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                if key in ("ID", "VERSION_ID", "PRETTY_NAME"):
                    distribution[key] = value.strip('"')
    current_umask = os.umask(0)
    os.umask(current_umask)
    return {
        "identity": os.environ.get("LINUX_RUNNER_ID", platform.node()),
        "architecture": platform.machine(),
        "kernel": platform.release(),
        "distribution": distribution,
        "shell": {"path": "/bin/sh", "version": tool_version("/bin/sh", [("--version",), tuple()])},
        "toolchain": tools,
        "autotools": autotools,
        "orderedConfigureArgv": shlex.split(os.environ.get("SLURM_CONFIGURE_ARGV", "")),
        "cachePolicy": "CCACHE_DISABLE=1; separate empty build roots",
        "umask": "%04o" % current_umask,
    }


def linux_observable(record):
    artifact = record["result"]["artifact"]
    if record["operationKind"] == "RuntimeRpath":
        return {"runtimePaths": artifact["runtimePaths"]}
    if record["operationKind"] == "EmbeddedReference":
        return {
            "symbols": artifact["symbols"],
            "boundaryLength": artifact["boundaryLength"],
            "payloadSha256": artifact["payloadSha256"],
            "consumerLinkHasNoBoundarySymbolUndefines": artifact["consumerLinkHasNoBoundarySymbolUndefines"],
            "gnuCommandPath": {"ld": True, "objcopy": True},
        }
    if record["operationKind"] == "DependencyRetention":
        return {"orderedNeeded": artifact["strongDirectLoadDependencies"], "retainsNoAsNeeded": "--no-as-needed" in record["effectiveLdArgs"]}
    raise DriverError("unknown Linux operation kind")


def validate_linux_records(records):
    failures = []
    for record in records:
        if record["result"]["exitStatus"] != 0 or record["result"]["artifactState"] != "present":
            failures.append("%s did not produce an artifact" % record["fixtureId"])
        observable = linux_observable(record)
        if record["operationKind"] == "RuntimeRpath" and observable["runtimePaths"] != [record["input"]["pathValue"]]:
            failures.append("%s runtime path mismatch" % record["fixtureId"])
        elif record["operationKind"] == "EmbeddedReference":
            if observable["payloadSha256"] != record["input"]["payloadSha256"] or observable["boundaryLength"] != record["input"]["payloadLength"] or not observable["consumerLinkHasNoBoundarySymbolUndefines"]:
                failures.append("%s reference observable mismatch" % record["fixtureId"])
        elif record["operationKind"] == "DependencyRetention":
            if observable["orderedNeeded"][:len(record["input"]["preLinkD"])] != record["input"]["preLinkD"] or not observable["retainsNoAsNeeded"]:
                failures.append("%s dependency observable mismatch" % record["fixtureId"])
    if failures:
        raise DriverError("; ".join(failures))


def capture_linux_baseline(args, environment, driver_path):
    validate_source_baseline(args.source_tree)
    manifest_path = args.evidence_dir / "darwin/baseline/manifest.json"
    manifest, manifest_digest = load_and_validate_manifest(manifest_path, driver_path)
    rules = source_rules(args.source_tree)
    records = execute_all_fixtures(args, environment, rules, darwin=False)
    validate_linux_records(records)
    runner = linux_runner_metadata(environment)
    preflight = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAtUtc": utc_now(),
        "baselineCommit": BASELINE_COMMIT,
        "runner": runner,
        "environmentAllowlist": normalized_env(controlled_environment(environment, args.build_root, linux=True), args.build_root),
        "interfaces": interface_metadata(driver_path),
        "darwinManifestSha256": manifest_digest,
        "passed": True,
    }
    atomic_write_json(args.evidence_dir / "linux/runner-preflight.json", preflight)
    contracts = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAtUtc": utc_now(),
        "baselineCommit": BASELINE_COMMIT,
        "runner": runner,
        "environmentAllowlist": normalized_env(controlled_environment(environment, args.build_root, linux=True), args.build_root),
        "interfaces": interface_metadata(driver_path),
        "darwinManifestSha256": manifest_digest,
        "fixtureDefinitionsSha256": manifest["interfaces"]["fixtureDefinitionsSha256"],
        "records": [{"fixtureId": record["fixtureId"], "operationKind": record["operationKind"], "input": record["input"], "observable": linux_observable(record)} for record in records],
    }
    directory = args.evidence_dir / "linux/baseline"
    if directory.exists() and any(directory.iterdir()):
        raise DriverError("Linux baseline evidence directory must be empty")
    directory.mkdir(parents=True, exist_ok=True)
    output = directory / "contracts.json"
    data = canonical_bytes(contracts)
    atomic_write_bytes(output, data)
    atomic_write_bytes(directory / "contracts.sha256", ("%s  contracts.json\n" % sha256_bytes(data)).encode("ascii"))
    print(str(output))


def load_linux_contract(path, driver_path):
    sidecar = path.with_name("contracts.sha256")
    if not path.is_file() or not sidecar.is_file():
        raise DriverError("Linux baseline contract or sidecar is missing")
    raw = path.read_bytes()
    digest = sha256_bytes(raw)
    if sidecar.read_text(encoding="ascii") != "%s  contracts.json\n" % digest:
        raise DriverError("Linux contract sidecar mismatch")
    contract = json.loads(raw.decode("utf-8"))
    if raw != canonical_bytes(contract):
        raise DriverError("Linux contract is not canonical JSON")
    if contract.get("baselineCommit") != BASELINE_COMMIT or contract.get("interfaces") != interface_metadata(driver_path):
        raise DriverError("Linux contract baseline/interface mismatch")
    return contract, digest


def verify_linux_preservation(args, environment, driver_path):
    contract, contract_digest = load_linux_contract(args.baseline_contract, driver_path)
    manifest, manifest_digest = load_and_validate_manifest(args.evidence_dir / "darwin/baseline/manifest.json", driver_path)
    runner = linux_runner_metadata(environment)
    current_env = normalized_env(controlled_environment(environment, args.build_root, linux=True), args.build_root)
    failures = []
    if runner != contract["runner"]:
        failures.append("runner/toolchain/configuration mismatch")
    if current_env != contract["environmentAllowlist"]:
        failures.append("environment mismatch")
    if manifest_digest != contract["darwinManifestSha256"] or manifest["interfaces"] != contract["interfaces"]:
        failures.append("Darwin manifest/interface mismatch")
    rules = source_rules(args.source_tree)
    records = execute_all_fixtures(args, environment, rules, darwin=False)
    validate_linux_records(records)
    baseline = {item["fixtureId"]: item for item in contract["records"]}
    comparisons = []
    for record in records:
        observable = linux_observable(record)
        expected = baseline.get(record["fixtureId"], {}).get("observable")
        passed = observable == expected
        comparisons.append({"fixtureId": record["fixtureId"], "operationKind": record["operationKind"], "observable": observable, "baselineObservable": expected, "passed": passed})
        if not passed:
            failures.append("%s observable contract changed" % record["fixtureId"])
    result = {
        "schemaVersion": SCHEMA_VERSION,
        "mode": args.mode,
        "createdAtUtc": utc_now(),
        "contractSha256": contract_digest,
        "interfaces": interface_metadata(driver_path),
        "comparisons": comparisons,
        "failures": failures,
        "passed": not failures,
    }
    output = args.evidence_dir / "linux/patched/results.json"
    atomic_write_json(output, result)
    if failures:
        raise DriverError("Linux preservation failed: %s" % "; ".join(failures))
    print(str(output))


def main():
    if len(sys.argv) < 2:
        raise DriverError("internal driver path argument is missing")
    driver_path = pathlib.Path(sys.argv[1]).resolve()
    args = parse_cli(sys.argv[2:])
    require_platform(args.mode)
    environment = validate_environment(args.mode)
    prepare_build_root(args.build_root)
    if args.mode == "freeze-darwin-baseline":
        freeze_darwin_baseline(args, environment, driver_path)
    elif args.mode == "verify-darwin-fix":
        verify_darwin_fix(args, environment, driver_path)
    elif args.mode == "verify-aggregate-diagnostics":
        verify_aggregate_diagnostics(args, environment, driver_path)
    elif args.mode == "capture-linux-baseline":
        capture_linux_baseline(args, environment, driver_path)
    elif args.mode == "verify-linux-preservation":
        verify_linux_preservation(args, environment, driver_path)


try:
    main()
except Inapplicable as error:
    sys.stderr.write("SKIP: %s\n" % error)
    sys.exit(77)
except DriverError as error:
    sys.stderr.write("ERROR: %s\n" % error)
    sys.exit(1)
except KeyboardInterrupt:
    sys.stderr.write("ERROR: interrupted\n")
    sys.exit(130)
PY
