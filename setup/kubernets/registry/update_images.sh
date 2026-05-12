#!/usr/bin/env bash
# 比对 images.conf 与 Registry 仓库现有镜像，执行同步操作
#
# 用法：
#   sudo ./update_images.sh [add|purge|conf_gen] [选项]
#
# 模式：
#   add (默认)  根据 images.conf 找出缺失镜像 -> 确认 -> 导入并推送
#   purge       找出 Registry 中超出 images.conf 的多余镜像 -> 确认 -> 删除并 GC
#   conf_gen    根据 Registry 当前镜像生成快照配置文件（不覆盖原有 conf）
#
# 选项：
#   --config FILE    Registry 部署配置文件（默认 ./registry.conf）
#   --images FILE    镜像配置文件（默认 ./images.conf）
#   --registry ADDR  Registry 地址（优先级最高，覆盖自动检测）
#
# 环境变量：
#   KUBECONFIG       kubectl 配置文件（默认 /etc/kubernetes/admin.conf）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
source "${LIB_DIR}/common.sh"

# --------------------------------------------------------------------------- #
# 参数解析
# --------------------------------------------------------------------------- #
MODE="add"
CONFIG_FILE="${SCRIPT_DIR}/registry.conf"
IMAGES_FILE="${SCRIPT_DIR}/images.conf"
REGISTRY_ADDR_OVERRIDE=""

usage() {
    cat >&2 <<EOF
用法: sudo $0 [add|purge|conf_gen] [选项]
  add (默认)  添加 images.conf 中有但 Registry 中缺失的镜像
  purge       删除 Registry 中有但 images.conf 中未定义的镜像
  conf_gen    生成当前 Registry 镜像的快照配置文件

选项:
  --config FILE    Registry 配置文件（默认 ./registry.conf）
  --images FILE    镜像配置文件（默认 ./images.conf）
  --registry ADDR  直接指定 Registry 地址（如 192.168.1.10:32000）
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        add|purge|conf_gen) MODE="$1"; shift ;;
        --config)   CONFIG_FILE="$2";            shift 2 ;;
        --images)   IMAGES_FILE="$2";            shift 2 ;;
        --registry) REGISTRY_ADDR_OVERRIDE="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *) die "未知参数: $1" ;;
    esac
done

# --------------------------------------------------------------------------- #
# 读取 Registry 部署配置
# --------------------------------------------------------------------------- #
REGISTRY_STORAGE=/data/registry
REGISTRY_PORT=32000
REGISTRY_HTTP=true
REGISTRY_K8S_NAMESPACE=kube-system

parse_registry_conf() {
    [[ -f "${CONFIG_FILE}" ]] || die "Registry 配置文件不存在: ${CONFIG_FILE}"
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ ^\[.*\]$ ]] && continue
        if [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            case "${key}" in
                REGISTRY_STORAGE)       REGISTRY_STORAGE="${val}"      ;;
                REGISTRY_PORT)          REGISTRY_PORT="${val}"          ;;
                REGISTRY_HTTP)          REGISTRY_HTTP="${val}"          ;;
                REGISTRY_K8S_NAMESPACE) REGISTRY_K8S_NAMESPACE="${val}" ;;
            esac
        fi
    done < "${CONFIG_FILE}"
}

# --------------------------------------------------------------------------- #
# 解析 Registry 地址
# --------------------------------------------------------------------------- #
REGISTRY_ADDR=""
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

resolve_registry_addr() {
    if [[ -n "${REGISTRY_ADDR_OVERRIDE}" ]]; then
        REGISTRY_ADDR="${REGISTRY_ADDR_OVERRIDE}"
        log_info "Registry 地址（手动指定）: ${REGISTRY_ADDR}"
        return
    fi

    local trust_conf="${SCRIPT_DIR}/registry-trust.conf"
    if [[ -f "${trust_conf}" ]]; then
        local addr
        addr=$(grep '^TRUST_REGISTRY_ADDR=' "${trust_conf}" 2>/dev/null | cut -d= -f2- || true)
        if [[ -n "${addr}" ]]; then
            REGISTRY_ADDR="${addr}"
            log_info "Registry 地址（来自 registry-trust.conf）: ${REGISTRY_ADDR}"
            return
        fi
    fi

    if [[ -f "${KUBECONFIG}" ]] && command -v kubectl &>/dev/null; then
        local master_ip
        master_ip=$(kubectl get nodes --kubeconfig "${KUBECONFIG}" \
            -l node-role.kubernetes.io/control-plane \
            -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' \
            2>/dev/null || true)
        if [[ -n "${master_ip}" ]]; then
            REGISTRY_ADDR="${master_ip}:${REGISTRY_PORT}"
            log_info "Registry 地址（集群自动检测）: ${REGISTRY_ADDR}"
            return
        fi
    fi

    die "无法确定 Registry 地址。请通过 --registry <addr> 手动指定，或确保 registry-trust.conf 存在。"
}

# --------------------------------------------------------------------------- #
# 读取镜像配置
# --------------------------------------------------------------------------- #
declare -A NS_PATHS
declare -a NS_ORDER

parse_images_conf() {
    [[ -f "${IMAGES_FILE}" ]] || die "镜像配置文件不存在: ${IMAGES_FILE}"
    log_info "读取镜像配置: ${IMAGES_FILE}"

    local cur_ns=""
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        if [[ "${line}" =~ ^\[namespace\.([a-zA-Z0-9_-]+)\]$ ]]; then
            cur_ns="${BASH_REMATCH[1]}"
            if [[ -z "${NS_PATHS[${cur_ns}]+x}" ]]; then
                NS_ORDER+=("${cur_ns}")
                NS_PATHS["${cur_ns}"]=""
            fi
            continue
        fi

        [[ "${line}" =~ ^\[.*\]$ ]] && { cur_ns=""; continue; }

        [[ -n "${cur_ns}" ]] && NS_PATHS["${cur_ns}"]+="${line}"$'\n'
    done < "${IMAGES_FILE}"

    log_info "  命名空间: ${NS_ORDER[*]:-（未定义）}"
}

# --------------------------------------------------------------------------- #
# 镜像名规范化
# --------------------------------------------------------------------------- #
_normalize_image_ref() {
    local img="$1"
    local host="${img%%/*}"
    host="${host%%:*}"
    if [[ "${host}" != *"."* && "${host}" != "localhost" ]]; then
        [[ "${img}" != *"/"* ]] && echo "docker.io/library/${img}" || echo "docker.io/${img}"
    else
        echo "${img}"
    fi
}

# --------------------------------------------------------------------------- #
# 从 tar 文件读取镜像名（不导入到 containerd）
# --------------------------------------------------------------------------- #
_read_names_from_tar()    { tar -xOf "$1" manifest.json 2>/dev/null  | grep -oP '"RepoTags":\["\K[^"]+' || true; }
_read_names_from_tar_gz() { tar -xzOf "$1" manifest.json 2>/dev/null | grep -oP '"RepoTags":\["\K[^"]+' || true; }

_read_names_from_file() {
    local file="$1"
    if [[ "${file}" == *.tar.gz ]]; then
        if tar -tzf "${file}" 2>/dev/null | grep -q "^manifest.json$"; then
            _read_names_from_tar_gz "${file}"
        else
            local wdir; wdir=$(mktemp -d /tmp/reg-scan-XXXXXX)
            # shellcheck disable=SC2064
            trap "rm -rf '${wdir}'" RETURN
            tar -xzf "${file}" -C "${wdir}" 2>/dev/null
            while IFS= read -r -d '' inner; do
                if tar -tf "${inner}" 2>/dev/null | grep -q "^manifest.json$"; then
                    _read_names_from_tar "${inner}"
                fi
            done < <(find "${wdir}" -name "*.tar" ! -name "*.tar.gz" -print0)
        fi
    elif [[ "${file}" == *.tar ]]; then
        if tar -tf "${file}" 2>/dev/null | grep -q "^manifest.json$"; then
            _read_names_from_tar "${file}"
        fi
    fi
}

# --------------------------------------------------------------------------- #
# 导入单个文件到 containerd，输出镜像名列表（nameref）
# --------------------------------------------------------------------------- #
_import_file() {
    local file="$1"
    local -n _out_names="$2"

    if [[ "${file}" == *.tar.gz ]]; then
        if tar -tzf "${file}" 2>/dev/null | grep -q "^manifest.json$"; then
            ctr -n k8s.io images import "${file}" &>/dev/null
            mapfile -t _out_names < <(_read_names_from_tar_gz "${file}")
        else
            local wdir; wdir=$(mktemp -d /tmp/reg-import-XXXXXX)
            # shellcheck disable=SC2064
            trap "rm -rf '${wdir}'" RETURN
            tar -xzf "${file}" -C "${wdir}"
            while IFS= read -r -d '' inner; do
                if tar -tf "${inner}" 2>/dev/null | grep -q "^manifest.json$"; then
                    ctr -n k8s.io images import "${inner}" &>/dev/null
                    mapfile -t -O "${#_out_names[@]}" _out_names < <(_read_names_from_tar "${inner}")
                fi
            done < <(find "${wdir}" -name "*.tar" ! -name "*.tar.gz" -print0)
        fi
    elif [[ "${file}" == *.tar ]]; then
        if tar -tf "${file}" 2>/dev/null | grep -q "^manifest.json$"; then
            ctr -n k8s.io images import "${file}" &>/dev/null
            mapfile -t _out_names < <(_read_names_from_tar "${file}")
        fi
    fi
}

# --------------------------------------------------------------------------- #
# 扫描 images.conf 中定义的镜像
# 结果: _CONF_REFS[<reg>/<ns>/<short>:<tag>]=<source_file>
# --------------------------------------------------------------------------- #
declare -A _CONF_REFS
declare -a _CONF_ORDER

scan_conf_images() {
    [[ ${#NS_ORDER[@]} -eq 0 ]] && { log_warn "images.conf 中未定义任何命名空间。"; return; }

    log_info "扫描 images.conf 中的镜像文件..."
    for ns in "${NS_ORDER[@]}"; do
        local paths="${NS_PATHS[${ns}]:-}"
        [[ -z "${paths}" ]] && continue

        local -a files=()
        while IFS= read -r path; do
            [[ -z "${path}" ]] && continue
            if [[ -d "${path}" ]]; then
                while IFS= read -r -d '' f; do
                    files+=("${f}")
                done < <(find "${path}" -type f \( -name "*.tar" -o -name "*.tar.gz" \) -print0 | sort -z)
            elif [[ -f "${path}" ]]; then
                files+=("${path}")
            else
                log_warn "  路径不存在，跳过: ${path}"
            fi
        done <<< "${paths}"

        for f in "${files[@]:-}"; do
            [[ -z "${f}" ]] && continue
            local -a names=()
            mapfile -t names < <(_read_names_from_file "${f}")
            if [[ ${#names[@]} -eq 0 ]]; then
                log_warn "  无法读取镜像名（RepoTags 为空），跳过: $(basename "${f}")"
                continue
            fi
            for img in "${names[@]}"; do
                [[ -z "${img}" ]] && continue
                local short_name="${img##*/}"
                local reg_ref="${REGISTRY_ADDR}/${ns}/${short_name}"
                if [[ -z "${_CONF_REFS[${reg_ref}]+x}" ]]; then
                    _CONF_REFS["${reg_ref}"]="${f}"
                    _CONF_ORDER+=("${reg_ref}")
                fi
            done
        done
    done
    log_info "  images.conf 镜像数: ${#_CONF_REFS[@]}"
}

# --------------------------------------------------------------------------- #
# 查询 Registry 中现有镜像
# 结果: _REG_REFS[<reg>/<repo>:<tag>]=1
# --------------------------------------------------------------------------- #
declare -A _REG_REFS
declare -a _REG_ORDER

query_registry_images() {
    log_info "查询 Registry 现有镜像..."
    local scheme; [[ "${REGISTRY_HTTP}" == "true" ]] && scheme="http" || scheme="https"
    local base_url="${scheme}://${REGISTRY_ADDR}"

    local catalog
    catalog=$(curl -sf "${base_url}/v2/_catalog" 2>/dev/null || echo '{"repositories":[]}')
    local -a repos=()
    mapfile -t repos < <(echo "${catalog}" | python3 -c \
        "import sys,json; [print(r) for r in json.load(sys.stdin).get('repositories',[])]" 2>/dev/null || true)

    for repo in "${repos[@]:-}"; do
        [[ -z "${repo}" ]] && continue
        local tags_json
        tags_json=$(curl -sf "${base_url}/v2/${repo}/tags/list" 2>/dev/null || echo '{}')
        local -a tags=()
        mapfile -t tags < <(echo "${tags_json}" | python3 -c \
            "import sys,json; [print(t) for t in (json.load(sys.stdin).get('tags') or [])]" 2>/dev/null || true)
        for tag in "${tags[@]:-}"; do
            [[ -z "${tag}" ]] && continue
            local ref="${REGISTRY_ADDR}/${repo}:${tag}"
            if [[ -z "${_REG_REFS[${ref}]+x}" ]]; then
                _REG_REFS["${ref}"]=1
                _REG_ORDER+=("${ref}")
            fi
        done
    done
    log_info "  Registry 现有镜像数: ${#_REG_REFS[@]}"
}

# --------------------------------------------------------------------------- #
# 删除 Registry 中的单个镜像（通过 digest）
# --------------------------------------------------------------------------- #
_delete_from_registry() {
    local ref="$1"
    local scheme; [[ "${REGISTRY_HTTP}" == "true" ]] && scheme="http" || scheme="https"

    local no_host="${ref#*/}"     # <repo>:<tag>
    local repo="${no_host%:*}"
    local tag="${no_host##*:}"
    local base_url="${scheme}://${REGISTRY_ADDR}"

    local digest
    digest=$(curl -sf -I \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "${base_url}/v2/${repo}/manifests/${tag}" 2>/dev/null \
        | grep -i "^Docker-Content-Digest:" | tr -d '\r' | awk '{print $2}' || true)

    if [[ -z "${digest}" ]]; then
        log_warn "  无法获取 digest，跳过: ${ref}"
        return
    fi

    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" -X DELETE \
        "${base_url}/v2/${repo}/manifests/${digest}" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "202" ]]; then
        log_info "  已删除: ${ref}  (${digest})"
    elif [[ "${http_code}" == "405" ]]; then
        log_warn "  Registry 未开启 DELETE（405）: ${ref}"
        log_warn "  请确认 Deployment 中已设置 REGISTRY_STORAGE_DELETE_ENABLED=true"
    else
        log_warn "  删除失败（HTTP ${http_code}）: ${ref}"
    fi
}

# --------------------------------------------------------------------------- #
# 运行 Registry GC
# --------------------------------------------------------------------------- #
_run_registry_gc() {
    if ! command -v kubectl &>/dev/null || [[ ! -f "${KUBECONFIG}" ]]; then
        log_warn "无法运行 GC：kubectl 不可用或 kubeconfig 不存在。"
        return
    fi
    local pod
    pod=$(kubectl get pods -n "${REGISTRY_K8S_NAMESPACE}" --kubeconfig "${KUBECONFIG}" \
        -l app=registry -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "${pod}" ]]; then
        log_warn "未找到 Registry Pod，跳过 GC。"
        return
    fi
    log_info "运行 Registry GC（pod: ${pod}）..."
    kubectl exec "${pod}" -n "${REGISTRY_K8S_NAMESPACE}" --kubeconfig "${KUBECONFIG}" \
        -- /bin/registry garbage-collect /etc/docker/registry/config.yml 2>&1 \
        | tail -5 || log_warn "GC 运行失败（非致命，存储可能未立即释放）。"
    log_info "GC 完成。"
}

# --------------------------------------------------------------------------- #
# 模式: add
# --------------------------------------------------------------------------- #
do_add() {
    local -a missing=()
    for ref in "${_CONF_ORDER[@]:-}"; do
        [[ -z "${ref}" ]] && continue
        [[ -z "${_REG_REFS[${ref}]+x}" ]] && missing+=("${ref}")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "所有镜像均已在 Registry 中，无需添加。"
        return
    fi

    echo
    log_info "以下 ${#missing[@]} 个镜像在 Registry 中缺失，将被添加："
    for ref in "${missing[@]}"; do
        log_info "  + ${ref}  (来源: ${_CONF_REFS[${ref}]})"
    done
    echo

    read -r -p "确认添加以上镜像？[y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || { log_info "用户取消，未执行任何操作。"; return; }

    command_exists ctr || die "未找到 ctr（containerd CLI），无法导入镜像。"

    # 按源文件分组，避免同一文件被重复导入
    declare -A src_to_refs   # src_to_refs[file]="ref1\nref2\n..."
    declare -a src_order
    for ref in "${missing[@]}"; do
        local src="${_CONF_REFS[${ref}]}"
        if [[ -z "${src_to_refs[${src}]+x}" ]]; then
            src_to_refs["${src}"]=""
            src_order+=("${src}")
        fi
        src_to_refs["${src}"]+="${ref}"$'\n'
    done

    local added=0
    for src in "${src_order[@]}"; do
        log_info "导入: $(basename "${src}")"

        local -a img_names=()
        _import_file "${src}" img_names

        if [[ ${#img_names[@]} -eq 0 ]]; then
            log_warn "  无法读取镜像名，跳过: $(basename "${src}")"
            continue
        fi

        # short_name:tag -> full normalized ref
        declare -A short_to_full
        for img in "${img_names[@]}"; do
            [[ -z "${img}" ]] && continue
            local full_img; full_img=$(_normalize_image_ref "${img}")
            local short_name="${img##*/}"
            short_to_full["${short_name}"]="${full_img}"
        done

        while IFS= read -r ref; do
            [[ -z "${ref}" ]] && continue
            local no_host="${ref#*/}"        # <ns>/<short>:<tag>
            local short_name="${no_host#*/}" # <short>:<tag>
            local full_img="${short_to_full[${short_name}]:-}"

            if [[ -z "${full_img}" ]]; then
                log_warn "  镜像名未匹配: ${short_name}，跳过"
                continue
            fi

            log_info "  -> ${ref}"
            if ctr -n k8s.io images tag "${full_img}" "${ref}" 2>&1; then
                if ctr -n k8s.io images push --plain-http "${ref}" 2>&1 | tail -1; then
                    log_info "     推送成功"
                    (( added++ )) || true
                else
                    log_warn "     推送失败: ${ref}"
                fi
            else
                log_warn "     tag 失败（源镜像: ${full_img}），跳过"
            fi
        done <<< "${src_to_refs[${src}]}"

        unset short_to_full
    done

    echo
    log_info "add 完成：成功推送 ${added} / ${#missing[@]} 个镜像。"
}

# --------------------------------------------------------------------------- #
# 模式: purge
# --------------------------------------------------------------------------- #
do_purge() {
    local -a extra=()
    for ref in "${_REG_ORDER[@]:-}"; do
        [[ -z "${ref}" ]] && continue
        [[ -z "${_CONF_REFS[${ref}]+x}" ]] && extra+=("${ref}")
    done

    if [[ ${#extra[@]} -eq 0 ]]; then
        log_info "Registry 中无多余镜像，无需清理。"
        return
    fi

    echo
    log_info "以下 ${#extra[@]} 个镜像在 images.conf 中未定义，将被删除："
    for ref in "${extra[@]}"; do
        log_info "  - ${ref}"
    done
    echo

    read -r -p "确认删除以上镜像？[y/N] " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || { log_info "用户取消，未执行任何操作。"; return; }

    local deleted=0
    for ref in "${extra[@]}"; do
        _delete_from_registry "${ref}" && (( deleted++ )) || true
    done

    log_info "已发送 ${deleted} 个删除请求，运行 GC 释放存储空间..."
    _run_registry_gc

    echo
    log_info "purge 完成：删除 ${deleted} / ${#extra[@]} 个镜像。"
}

# --------------------------------------------------------------------------- #
# 模式: conf_gen
# --------------------------------------------------------------------------- #
do_conf_gen() {
    if [[ ${#_REG_REFS[@]} -eq 0 ]]; then
        log_warn "Registry 中没有任何镜像，生成的配置文件将为空。"
    fi

    local ts; ts=$(date '+%Y%m%d_%H%M%S')
    local out_file="${SCRIPT_DIR}/images.conf.generated-${ts}"

    {
        echo "# -----------------------------------------------------------------------"
        echo "# 由 update_images.sh conf_gen 自动生成"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Registry : ${REGISTRY_ADDR}"
        echo "# 此文件记录 Registry 中现有镜像，路径字段仅为参考，非源文件路径"
        echo "# -----------------------------------------------------------------------"
        echo

        declare -A ns_refs
        declare -a ns_list
        for ref in "${_REG_ORDER[@]:-}"; do
            [[ -z "${ref}" ]] && continue
            local no_host="${ref#*/}"
            local ns="${no_host%%/*}"
            if [[ -z "${ns_refs[${ns}]+x}" ]]; then
                ns_refs["${ns}"]=""
                ns_list+=("${ns}")
            fi
            ns_refs["${ns}"]+="# ${ref}"$'\n'
        done

        for ns in "${ns_list[@]:-}"; do
            echo "[namespace.${ns}]"
            printf "%s" "${ns_refs[${ns}]}"
            echo
        done
    } > "${out_file}"

    echo
    log_info "conf_gen 完成：配置快照已写入 ${out_file}"
    log_info "（原有 images.conf 未被修改）"
}

# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
main() {
    require_root

    log_info "=== update_images.sh  模式: ${MODE} ==="

    parse_registry_conf
    resolve_registry_addr

    case "${MODE}" in
        add)
            parse_images_conf
            scan_conf_images
            query_registry_images
            do_add
            ;;
        purge)
            parse_images_conf
            scan_conf_images
            query_registry_images
            do_purge
            ;;
        conf_gen)
            query_registry_images
            do_conf_gen
            ;;
    esac
}

main "$@"
