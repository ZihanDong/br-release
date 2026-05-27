# Skills — Agent-Callable Knowledge Base

This directory contains skill files for use by Claude Code agents. Each skill is a self-contained markdown document describing how to accomplish a specific task using the tools in this repository.

## Available Skills

| Skill | File | Description |
|-------|------|-------------|
| `k8s` | [k8s.md](k8s.md) | All k8s operations: cluster setup, node modes, private registry, cleanup |
| `vllm` | [vllm.md](vllm.md) | Launch vLLM inference servers (Docker + k8s) on BirenTech GPU nodes; scripts: vllm_server.sh + run_docker.sh + k8s_yaml_gen.sh + k8s_apply.sh |
| `vllm-script-to-conf` | [vllm-script-to-conf.md](vllm-script-to-conf.md) | Convert raw vLLM launch scripts (start_<model>.sh) into structured conf files under configs/ |

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
| `infer/llm/vllm/vllm_server.sh` | Inner container script (runs inside container, execs vLLM) |
| `infer/llm/vllm/run_docker.sh` | Outer Docker launcher (GPU select + docker run) |
| `infer/llm/vllm/k8s_yaml_gen.sh` | k8s YAML generator (saves to k8s_yaml_gen/, no apply) |
| `infer/llm/vllm/k8s_apply.sh` | k8s deploy + test (kubectl apply + wait Ready/Running + API smoke test or interactive shell) |
| `infer/llm/vllm/README.md` | Full Chinese vLLM documentation |
