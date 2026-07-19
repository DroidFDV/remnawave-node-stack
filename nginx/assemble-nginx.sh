#!/usr/bin/env bash
# Собирает nginx/nginx.conf.template из фрагментов в nginx/fragments/.
#
# Usage:
#   ./nginx/assemble-nginx.sh
#   ./nginx/assemble-nginx.sh --parts xhttp,grpc --fallback decoy
#   ./nginx/assemble-nginx.sh --list
#   ./nginx/assemble-nginx.sh --dry-run
#
# Переменные .env (корень репозитория):
#   NGINX_PARTS=xhttp,grpc     # xhttp | grpc | ws (хотя бы один)
#   NGINX_FALLBACK=decoy       # decoy | drop444

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRAGMENTS_DIR="$SCRIPT_DIR/fragments"
OUTPUT_FILE="$SCRIPT_DIR/nginx.conf.template"
ENV_FILE="$PROJECT_ROOT/.env"

NGINX_PARTS="${NGINX_PARTS:-xhttp,grpc}"
NGINX_FALLBACK="${NGINX_FALLBACK:-decoy}"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: assemble-nginx.sh [OPTIONS]

Options:
  --parts LIST     Comma-separated: xhttp,grpc,ws (default from .env or xhttp,grpc)
  --fallback MODE  decoy | drop444 (default from .env or decoy)
  --list           List available fragments
  --dry-run        Print assembled config to stdout
  -h, --help       Show this help

Environment (.env in repo root):
  NGINX_PARTS      xhttp,grpc,ws
  NGINX_FALLBACK   decoy | drop444
EOF
}

list_fragments() {
    echo "Available fragments in $FRAGMENTS_DIR:"
    ls -1 "$FRAGMENTS_DIR"/*.conf 2>/dev/null | sort | while read -r f; do
        basename "$f"
    done
    echo ""
    echo "Part aliases (NGINX_PARTS):"
    echo "  xhttp  -> 20-location-xhttp.conf"
    echo "  grpc   -> 21-location-grpc.conf"
    echo "  ws     -> 22-location-ws.conf"
    echo ""
    echo "Fallback modes (NGINX_FALLBACK):"
    echo "  decoy    -> 30-fallback-decoy.conf"
    echo "  drop444  -> 31-fallback-drop444.conf"
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --parts)
                NGINX_PARTS="${2:?--parts requires a value}"
                shift 2
                ;;
            --fallback)
                NGINX_FALLBACK="${2:?--fallback requires a value}"
                shift 2
                ;;
            --list)
                list_fragments
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

has_part() {
    local needle="$1"
    local part
    IFS=',' read -ra parts <<< "$NGINX_PARTS"
    for part in "${parts[@]}"; do
        part="${part// /}"
        if [[ "$part" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

validate() {
    if ! has_part xhttp && ! has_part grpc && ! has_part ws; then
        echo "Error: NGINX_PARTS must include at least one of: xhttp, grpc, ws" >&2
        echo "Current: $NGINX_PARTS" >&2
        exit 1
    fi

    case "$NGINX_FALLBACK" in
        decoy|drop444) ;;
        *)
            echo "Error: NGINX_FALLBACK must be decoy or drop444 (got: $NGINX_FALLBACK)" >&2
            exit 1
            ;;
    esac
}

append_fragment() {
    local name="$1"
    local path="$FRAGMENTS_DIR/$name"
    if [[ ! -f "$path" ]]; then
        echo "Error: missing fragment $path" >&2
        exit 1
    fi
    cat "$path"
}

assemble() {
    local out
    out="$(mktemp)"

    append_fragment "00-main.conf" > "$out"
    append_fragment "10-server-443-head.conf" >> "$out"

    if has_part xhttp; then
        append_fragment "20-location-xhttp.conf" >> "$out"
    fi
    if has_part grpc; then
        append_fragment "21-location-grpc.conf" >> "$out"
    fi
    if has_part ws; then
        append_fragment "22-location-ws.conf" >> "$out"
    fi

    case "$NGINX_FALLBACK" in
        decoy)
            append_fragment "30-fallback-decoy.conf" >> "$out"
            ;;
        drop444)
            append_fragment "31-fallback-drop444.conf" >> "$out"
            ;;
    esac

    append_fragment "40-server-443-foot.conf" >> "$out"
    append_fragment "50-server-80.conf" >> "$out"
    append_fragment "99-http-foot.conf" >> "$out"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        cat "$out"
        rm -f "$out"
        return 0
    fi

    cp "$out" "$OUTPUT_FILE"
    rm -f "$out"
    echo "Assembled: $OUTPUT_FILE"
    echo "  NGINX_PARTS=$NGINX_PARTS"
    echo "  NGINX_FALLBACK=$NGINX_FALLBACK"
}

load_env
parse_args "$@"
validate
assemble
