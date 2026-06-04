#!/usr/bin/env bash
# conf_gen.sh — Interactive / non-interactive model-config editor.
# Works on any infer/llm/configs/*.conf (vLLM or SGLang); it only edits
# key=value lines, preserving comments and structure.
#
# Usage:
#   Interactive:     conf_gen.sh <conf_file>
#   Non-interactive: conf_gen.sh <conf_file> --key1 val1 --key2 val2 ...
#
# Interactive: prompts for each key=value (Enter = keep).
# Non-interactive: applies --key val overrides directly, no prompts.
# Writes changed values into a new file whose name encodes the changes
# (e.g. vllm_minimax-m2.5_max_model_len-18000.conf).

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <conf_file> [--key val ...]" >&2
    exit 1
fi

conf_file="$1"
shift

if [[ ! -f "$conf_file" ]]; then
    echo "Error: file not found: $conf_file" >&2
    exit 1
fi

conf_dir="$(dirname "$conf_file")"
conf_basename="$(basename "$conf_file")"
conf_ext="${conf_basename##*.}"
conf_stem="${conf_basename%.*}"

declare -a all_lines=()
declare -A var_values=()
declare -a var_order=()
declare -A new_values=()
declare -a changed_vars=()

# Parse: keep all lines verbatim; record key=value entries
while IFS= read -r line || [[ -n "$line" ]]; do
    all_lines+=("$line")
    if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        var_values["$key"]="$val"
        var_order+=("$key")
    fi
done < "$conf_file"

# --- Non-interactive mode: --key val pairs provided on command line ---
if [[ $# -gt 0 ]]; then
    while [[ $# -gt 0 ]]; do
        arg="$1"
        if [[ "$arg" =~ ^--([a-zA-Z_][a-zA-Z0-9_]*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            if [[ $# -lt 2 ]]; then
                echo "Error: --${key} requires a value" >&2
                exit 1
            fi
            val="$2"
            shift 2
            if [[ ! -v var_values["$key"] ]]; then
                echo "Warning: '$key' not found in $conf_basename, skipping" >&2
                continue
            fi
            if [[ "$val" != "${var_values[$key]}" ]]; then
                new_values["$key"]="$val"
                changed_vars+=("$key")
            fi
        else
            echo "Error: expected --key, got: $arg" >&2
            exit 1
        fi
    done
    echo "=== Non-interactive conf update: $conf_basename ==="
    echo ""

# --- Interactive mode: prompt for each variable ---
else
    echo "=== Interactive conf editor: $conf_basename ==="
    echo "Press Enter to keep the current value, or type a new value and press Enter."
    echo ""

    for key in "${var_order[@]}"; do
        current="${var_values[$key]}"
        printf "  %s = [%s]\n  New value (Enter to keep): " "$key" "$current"
        if ! read -r input; then
            echo ""
            break
        fi
        if [[ -n "$input" && "$input" != "$current" ]]; then
            new_values["$key"]="$input"
            changed_vars+=("$key")
        fi
    done

    echo ""
fi

if [[ ${#changed_vars[@]} -eq 0 ]]; then
    echo "No changes made. Exiting."
    exit 0
fi

echo "Changed variables:"
for key in "${changed_vars[@]}"; do
    echo "  $key: [${var_values[$key]}] -> [${new_values[$key]}]"
done
echo ""

# Build filename suffix: _key1-val1_key2-val2 (sanitize special chars)
suffix=""
for key in "${changed_vars[@]}"; do
    val="${new_values[$key]}"
    # Strip quotes/braces, replace whitespace and path chars with hyphens
    sanitized="$(printf '%s' "$val" | tr -d "'\"{}" | tr ' /\\:,' '-----')"
    suffix+="_${key}-${sanitized}"
done

new_filename="${conf_stem}${suffix}.${conf_ext}"
new_filepath="${conf_dir}/${new_filename}"

# Write new conf preserving comments and structure
{
    for line in "${all_lines[@]}"; do
        if [[ "$line" =~ ^([a-zA-Z_][a-zA-Z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            if [[ -v new_values["$key"] ]]; then
                printf '%s\n' "${key}=${new_values[$key]}"
            else
                printf '%s\n' "$line"
            fi
        else
            printf '%s\n' "$line"
        fi
    done
} > "$new_filepath"

echo "Written: $new_filepath"
