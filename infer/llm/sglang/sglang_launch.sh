#!/usr/bin/env bash
# sglang_launch.sh — single source of truth for HOW an SGLang server is launched,
# branching on launch_mode (standard LLM / multimodal_gen image / video_gen).
#
# Sourced by sglang/sglang_server.sh — the single in-container launcher used by
# BOTH Docker (run_docker.sh writes a run script that exec's sglang_server.sh) and
# k8s (k8s_yaml_gen.sh bakes `bash sglang_server.sh <conf>` into the workload). So
# the launch_mode branching lives in exactly one place and Docker/k8s stay identical.
#
# Precondition (caller must have run these first, so the conf vars + weight path
# are in scope): parse_config "<ref>" sglang   and   parse_model "<model_weights>"
# (which sets MODEL_PATH).
#
# sglang_build_launch   -> populates these globals:
#     LAUNCH_ENV[]   array of "KEY=VALUE" env to export before the server starts
#     LAUNCH_PRE     shell snippet to run right before exec (e.g. mkdir outputs,
#                    source the BirenTech base env) — may be empty
#     LAUNCH_CMD[]   argv of the server process

_SGLANG_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

sglang_build_launch() {
    LAUNCH_ENV=(); LAUNCH_PRE=""; LAUNCH_CMD=()
    local mode="${launch_mode:-standard}"

    if [[ "$mode" == "multimodal_gen" ]]; then
        # ── Image generation (Qwen-Image, sglang.multimodal_gen) ──
        # These BRTB/SUDNN flags must be in the environment BEFORE torch/sglang_br
        # import, so they are exported (not passed as args).
        LAUNCH_ENV=(
            BRTB_ENABLE_SUPA_FALLBACK=1
            BRTB_ENABLE_NCDHW=1
            BRTB_ENABLE_FORCE_EAGER_CONV2D=1
            SUDNN_EAGER_ENABLE_ALPHA_BETA=false
        )
        LAUNCH_PRE="mkdir -p ${output_path}"
        # multimodal_gen has no `python3 -m` entry, and it forces multiprocessing
        # 'spawn' — so the launcher MUST be a real importable file (workers re-import
        # it to re-register the SUPA platform). launch_multimodal_gen.py is that thin,
        # generic entry (no hardcoded args); mirrors the LLM `python3 -m ...` style.
        LAUNCH_CMD=(
            python3 "${_SGLANG_LAUNCH_DIR}/launch_multimodal_gen.py"
            --model-path "${MODEL_PATH}"
            --num-gpus "${tensor_parallel_size}"
            --tp-size "${tensor_parallel_size}"
            --host 0.0.0.0
            --port "${port}"
            --output-path "${output_path}"
            --dit-cpu-offload "${dit_cpu_offload}"
            --dit-layerwise-offload "${dit_layerwise_offload}"
            --image-encoder-cpu-offload "${image_encoder_cpu_offload}"
            --text-encoder-cpu-offload "${text_encoder_cpu_offload}"
            --vae-cpu-offload "${vae_cpu_offload}"
        )
        # NB: this multimodal_gen build has no --served-model-name; the
        # /v1/images/generations API takes an optional 'model' in the request body.

    elif [[ "$mode" == "video_gen" ]]; then
        # ── Wan2.2 video generation (t2v/i2v auto-detected from model_index.json) ──
        # Uses the SAME generic, spawn-safe entry as image gen (launch_multimodal_gen.py):
        # both are sglang.multimodal_gen servers, so only the env + args differ. The Wan
        # BRTB/SUDNN tuning (mirrors the offline test/multimodal_gen/wan/offline) MUST be
        # in the environment before torch/sglang_br import, so it is exported here and
        # inherited by the spawned workers — not set inside the Python entry.
        # tensor_parallel_size = TOTAL cards; ulysses × ring × (cfg?2:1) must equal it.
        LAUNCH_ENV=(
            # SUDNN kernel cache (persisted under CWD/kernel_cache, created in LAUNCH_PRE)
            SUDNN_KERNEL_CACHE_CAPACITY=30000
            SUDNN_KERNEL_CACHE_EXCLUDE_UID=1
            SUDNN_KERNEL_CACHE_FOLDER=./kernel_cache
            SUDNN_KERNEL_CACHE_DISK_LEVEL=3
            SUDNN_KERNEL_CACHE_MAX_SIZE_MB=10240
            # BirenTech backend tuning for Wan DiT
            BRTB_ENABLE_FORCE_UMA=1
            BRTB_ENABLE_FORCE_SUDNN_CONV2d=1
            SUCCL_BUFFSIZE=16777216
            BRTB_DISABLE_L2_FLUSH=1
            BRTB_ENABLE_SUBLAS_API=1
            BRTB_ENABLE_WEIGHT_BYPASS=1
            BRTB_ENABLE_REGISTER_BEFORE_D2H=1
            PYTORCH_SUPA_ALLOC_CONF=max_split_size_mb:512
            BRTB_DISABLE_ZERO_REORDER=1
            BRTB_DISABLE_ZERO_OUTPUT_NUMA=1
            BRTB_DISABLE_ZERO_OUTPUT_UMA=1
            BRTB_DISABLE_ZERO_WS=1
            BRTB_ENABLE_NCDHW=1
            BRTB_ENABLE_EAGER_ADV_API=1
            BRTB_DUMP_MEM_POOL_WHEN_OOM=1
            OMP_NUM_THREADS=16
            SHAPE_TRANSFORM_MIN_GRAN=2048
            BRTB_ENABLE_FORCE_CONV_BB=1
            TORCHDYNAMO_DISABLE=1
            # sp split inside DiT stage; ring attention oneshot allgather (faster than p2p)
            BRTB_ENABLE_SP_SPLIT_IN_STAGE=1
            RING_ATTN_USE_ONESHOT_ALLGATHER=1
            # i2v max area cap (720*1280); per-request `size` still sets width×height
            SET_WAN_CONFIG_MAX_AREA=921600
            BR_UMD_TRACE=0
            BR_UMD_TRACE_LEVEL=0
            BR_UMD_TRACE_EXCEPTION=0
        )
        # Pre-launch: source the BirenTech base env (SUDNN/SUCCL paths) if present; ensure
        # cache_dit (the Wan pipeline imports cache_dit.parallelism; pin 1.3.4 — latest
        # renamed it). Redundant-but-safe when launched with `--env 2604-rc2` (whose setup
        # already installs cache_dit); keep so a bare `run_docker.sh wan2.2-…` also works.
        LAUNCH_PRE='_brsw="/usr/local/birensupa/base/latest/scripts/brsw_set_env.sh"; if [[ -f "$_brsw" ]]; then set +eu; source "$_brsw" || true; set -eu; fi; unset _brsw'
        LAUNCH_PRE+='; python3 -c "import cache_dit.parallelism" >/dev/null 2>&1 || pip install --no-deps cache_dit==1.3.4 >/dev/null 2>&1 || true'
        LAUNCH_PRE+="; mkdir -p ${output_path} ./kernel_cache"
        LAUNCH_CMD=(
            python3 "${_SGLANG_LAUNCH_DIR}/launch_multimodal_gen.py"
            --model-path "${MODEL_PATH}"
            --num-gpus "${tensor_parallel_size}"
            --tp-size 1
            --ulysses-degree "${ulysses_degree}"
            --ring-degree "${ring_degree}"
            --host 0.0.0.0
            --port "${port}"
            --output-path "${output_path}"
            --dit-layerwise-offload "${dit_layerwise_offload}"
            --text-encoder-cpu-offload "${text_encoder_cpu_offload}"
            --vae-cpu-offload "${vae_cpu_offload}"
            --vae-precision bf16
        )
        [[ "${enable_cfg_parallel,,}" == "true" ]] && LAUNCH_CMD+=(--enable-cfg-parallel)

    else
        # ── Standard LLM (sglang.launch_server, OpenAI-compatible) ──
        LAUNCH_ENV=(
            BRTB_PLAN_ID_RENEW=1
            BRTB_DISABLE_ZERO_REORDER=1
            BRTB_DISABLE_ZERO_OUTPUT_NUMA=1
            BRTB_DISABLE_ZERO_OUTPUT_UMA=1
            BRTB_DISABLE_ZERO_WS=1
            BRTB_DISABLE_L2_FLUSH=1
            BRTB_ENABLE_SUPA_FILL=1
        )
        LAUNCH_CMD=(
            python3 -m sglang.launch_server
            --host 0.0.0.0
            --port "${port}"
            --model-path "${MODEL_PATH}"
            --tp-size "${tensor_parallel_size}"
            --pp-size "${pipeline_parallel_size}"
            --mem-fraction-static "${mem_fraction_static}"
            --max-model-len "${max_model_len}"
            --max-running-requests "${max_running_requests}"
            --page-size "${page_size}"
        )
        [[ "${trust_remote_code:-}" == "true" ]]   && LAUNCH_CMD+=(--trust-remote-code)
        [[ "${disable_radix_cache:-}" == "true" ]] && LAUNCH_CMD+=(--disable-radix-cache)
        [[ -n "${served_model_name:-}" ]]          && LAUNCH_CMD+=(--served-model-name "${served_model_name}")
    fi

    # extra_env / extra_sglang_args from the conf apply to every mode.
    if [[ -n "${extra_env:-}" ]]; then
        local _kv; for _kv in ${extra_env}; do LAUNCH_ENV+=("$_kv"); done
    fi
    if [[ -n "${extra_sglang_args:-}" ]]; then
        local _arr; read -ra _arr <<< "${extra_sglang_args}"; LAUNCH_CMD+=("${_arr[@]}")
    fi
}
