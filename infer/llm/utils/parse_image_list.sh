#!/usr/bin/env bash
# Parse a framework "image list" file — the catalog of base container images a
# framework can run, plus the in-container setup each one needs to be brought up
# to a model-runnable state (e.g. installing pip deps the image is missing).
#
# Used by sglang/run_docker.sh, vllm/run_docker.sh and utils/k8s_yaml_gen.sh via
# the optional flags:
#   --env <name>        select the image entry named <name>
#   --env-list <file>   use <file> instead of the framework's default list
#                       (sglang/sglang_images.list or vllm/vllm_images.list)
# When --env is not given, callers keep their existing default image and run no
# setup, so this file is purely additive.
#
# File format — one INI-style section per selectable base image:
#   [<name>]                       # retrieval name passed to --env
#   image = <docker image[:tag]>   # base image (overrides the config's docker_image / k8s_image)
#   desc  = <one-line description> # optional, human-readable
#   setup = <shell command>        # run inside the container BEFORE the server starts;
#   setup = <another command>      #   repeat for multiple steps (joined with ' && ').
#                                  #   omit / leave empty for no setup.
# Lines whose first non-blank char is '#' are comments. Avoid embedding a double
# quote (") in a setup command — k8s injects setup into a double-quoted YAML arg.
#
# Functions (source this file, then call):
#   parse_image_list <file> <name>  -> on success sets IMG_NAME, IMG_DESC, IMG_SETUP
#                                       (IMG_SETUP = setup steps joined by ' && '); returns 1 on error
#   list_image_envs  <file>          -> prints the available entries (name / image / desc)

parse_image_list() {
    local file="$1" want="$2"
    IMG_NAME=""; IMG_DESC=""; IMG_SETUP=""

    [[ -f "$file" ]] || { echo -e "\033[0;31m[ERR ]\033[0m  image list file not found: $file" >&2; return 1; }
    [[ -n "$want" ]] || { echo -e "\033[0;31m[ERR ]\033[0m  no env name given to parse_image_list" >&2; return 1; }

    local cur="" found=0 line t key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        # left-trim for comment / section detection
        t="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$t" || "${t:0:1}" == "#" ]] && continue

        if [[ "$t" =~ ^\[(.+)\][[:space:]]*$ ]]; then
            cur="${BASH_REMATCH[1]}"
            [[ "$cur" == "$want" ]] && found=1
            continue
        fi
        [[ "$cur" == "$want" ]] || continue
        [[ "$t" == *=* ]] || continue

        key="${t%%=*}"; val="${t#*=}"
        # trim whitespace from both ends of key and value
        key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"

        case "$key" in
            image) IMG_NAME="$val" ;;
            desc)  IMG_DESC="$val" ;;
            setup) [[ -n "$val" ]] && { if [[ -n "$IMG_SETUP" ]]; then IMG_SETUP="${IMG_SETUP} && ${val}"; else IMG_SETUP="$val"; fi; } ;;
        esac
    done < "$file"

    if [[ "$found" != 1 ]]; then
        local avail; avail=$(grep -oE '^[[:space:]]*\[.+\]' "$file" 2>/dev/null | tr -d '[] \t' | tr '\n' ' ')
        echo -e "\033[0;31m[ERR ]\033[0m  env '$want' not found in $file" >&2
        echo "        available envs: ${avail:-<none>}" >&2
        return 1
    fi
    [[ -n "$IMG_NAME" ]] || { echo -e "\033[0;31m[ERR ]\033[0m  env '$want' in $file has no 'image=' field" >&2; return 1; }
    return 0
}

list_image_envs() {
    local file="$1"
    [[ -f "$file" ]] || { echo "  (no image list: $file)"; return 1; }
    awk '
        { sub(/\r$/,"") }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[.+\][[:space:]]*$/ {
            n=$0; sub(/^[[:space:]]*\[/,"",n); sub(/\][[:space:]]*$/,"",n); printf "  %s\n", n; next
        }
        /^[[:space:]]*image[[:space:]]*=/ { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]+$/,"",v); printf "      image: %s\n", v; next }
        /^[[:space:]]*desc[[:space:]]*=/  { v=$0; sub(/^[^=]*=[[:space:]]*/,"",v); sub(/[[:space:]]+$/,"",v); if (v!="") printf "      desc : %s\n", v; next }
    ' "$file"
}
