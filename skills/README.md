# Skills — Agent-Callable Knowledge Base

This directory contains skill files for use by Claude Code agents. Each skill is a self-contained markdown document describing how to accomplish a specific task using the tools in this repository.

## Available Skills

| Skill | File | Description |
|-------|------|-------------|
| `k8s` | [k8s.md](k8s.md) | All k8s operations: cluster setup, node modes, private registry, cleanup |
| `vllm` | [vllm.md](vllm.md) | Launch vLLM inference servers (Docker + k8s) on BirenTech GPU nodes; three-script arch: inner start_vllm_server.sh + outer docker/k8s launchers |

## How to Use in an Agent

When an agent needs to perform any Kubernetes-related task using this repo's tooling, read the skill file first:

```
Read: skills/k8s.md
```

The skill file provides:
- Script map (which script does what)
- Environment variables and their defaults
- Expected side effects and what is/isn't affected
- Verification commands
- Common failure modes and fixes

## Key Paths

| Path | Description |
|------|-------------|
| `setup/kubernets/` | Main k8s scripts root |
| `setup/kubernets/registry/` | Registry management scripts |
| `setup/samples/` | End-to-end demo scripts (01–04) |
| `setup/kubernets/README.md` | Full Chinese k8s documentation |
| `infer/llm/vllm/` | vLLM server scripts root |
| `infer/llm/vllm/configs/` | Per-model vLLM run configs |
| `infer/llm/vllm/start_vllm_server.sh` | Inner container script (runs inside container, execs vLLM) |
| `infer/llm/vllm/start_vllm_docker.sh` | Outer Docker launcher (GPU select + docker run) |
| `infer/llm/vllm/start_vllm_k8s.sh` | Outer k8s launcher (generates YAML, mounts script dir) |
| `infer/llm/vllm/README.md` | Full Chinese vLLM documentation |
