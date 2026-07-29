#!/usr/bin/env bash
# Собирает xray/configs/xray-generated.json из фрагментов в xray/fragments/.
#
# Usage:
#   ./xray/assemble-xray.sh
#   ./xray/assemble-xray.sh --parts xhttp,grpc,ws --hy2-mode salamander
#   ./xray/assemble-xray.sh --list
#   ./xray/assemble-xray.sh --dry-run
#
# Переменные .env (корень репозитория):
#   XRAY_PARTS=xhttp,grpc          # xhttp | grpc | ws | hysteria2 (хотя бы один)
#   XRAY_HY2_MODE=salamander       # salamander | gecko | off
#   XRAY_OUTPUT=xray/configs/xray-generated.json  # относительно ROOT
#   HY2_UDP_PORT=443
#   HY2_OBFS_PASSWORD=...

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

FRAGMENTS_REL="xray/fragments"
ENV_FILE=".env"

XRAY_PARTS="${XRAY_PARTS:-xhttp,grpc}"
XRAY_HY2_MODE="${XRAY_HY2_MODE:-off}"
XRAY_OUTPUT="${XRAY_OUTPUT:-xray/configs/xray-generated.json}"
HY2_UDP_PORT="${HY2_UDP_PORT:-443}"
HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-CHANGE_ME_HY2_PASSWORD}"
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: assemble-xray.sh [OPTIONS]

Options:
  --parts LIST      Comma-separated: xhttp,grpc,ws,hysteria2 (default from .env or xhttp,grpc)
  --hy2-mode MODE   salamander | gecko | off (default from .env or off)
  --output PATH     Output path relative to repo root (default: xray/configs/xray-generated.json)
  --list            List available fragments and aliases
  --dry-run         Print assembled config to stdout
  -h, --help        Show this help

Environment (.env in repo root; paths relative to repo root):
  XRAY_PARTS         xhttp,grpc,ws,hysteria2
  XRAY_HY2_MODE      salamander | gecko | off
  XRAY_OUTPUT        relative path for generated JSON
  HY2_UDP_PORT       UDP port for HYSTERIA2 inbound
  HY2_OBFS_PASSWORD  finalmask password (Panel / clients)
EOF
}

list_fragments() {
    echo "Available fragments in ${FRAGMENTS_REL}/:"
    ls -1 "${FRAGMENTS_REL}"/*.json 2>/dev/null | sort | while read -r f; do
        basename "$f"
    done
    echo ""
    echo "Part aliases (XRAY_PARTS):"
    echo "  xhttp      -> 20-inbound-xhttp.json"
    echo "  grpc       -> 21-inbound-grpc.json"
    echo "  ws         -> 22-inbound-ws.json"
    echo "  hysteria2  -> 23/24-inbound-hysteria2-*.json (by XRAY_HY2_MODE)"
    echo ""
    echo "HY2 modes (XRAY_HY2_MODE):"
    echo "  off         -> no HYSTERIA2"
    echo "  salamander  -> include HY2 (23-inbound-hysteria2-salamander.json)"
    echo "  gecko       -> include HY2 (24-inbound-hysteria2-gecko.json)"
    echo ""
    echo "Note: if hysteria2 is in XRAY_PARTS, XRAY_HY2_MODE must be salamander or gecko."
}

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$ENV_FILE"
        set +a
    fi
    XRAY_PARTS="${XRAY_PARTS:-xhttp,grpc}"
    XRAY_HY2_MODE="${XRAY_HY2_MODE:-off}"
    XRAY_OUTPUT="${XRAY_OUTPUT:-xray/configs/xray-generated.json}"
    HY2_UDP_PORT="${HY2_UDP_PORT:-443}"
    HY2_OBFS_PASSWORD="${HY2_OBFS_PASSWORD:-CHANGE_ME_HY2_PASSWORD}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --parts)
                XRAY_PARTS="${2:?--parts requires a value}"
                shift 2
                ;;
            --hy2-mode)
                XRAY_HY2_MODE="${2:?--hy2-mode requires a value}"
                shift 2
                ;;
            --output)
                XRAY_OUTPUT="${2:?--output requires a value}"
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
    IFS=',' read -ra parts <<< "$XRAY_PARTS"
    for part in "${parts[@]}"; do
        part="${part// /}"
        if [[ "$part" == "$needle" ]]; then
            return 0
        fi
    done
    return 1
}

require_relative_path() {
    local label="$1"
    local path="$2"
    if [[ -z "$path" ]]; then
        echo "Error: $label must not be empty" >&2
        exit 1
    fi
    if [[ "$path" = /* ]]; then
        echo "Error: $label must be relative to repo root (got absolute: $path)" >&2
        exit 1
    fi
    case "$path" in
        *..*)
            echo "Error: $label must not contain '..' (got: $path)" >&2
            exit 1
            ;;
    esac
}

validate() {
    require_relative_path "XRAY_OUTPUT" "$XRAY_OUTPUT"
    require_relative_path "fragments dir" "$FRAGMENTS_REL"

    if ! has_part xhttp && ! has_part grpc && ! has_part ws && ! has_part hysteria2; then
        echo "Error: XRAY_PARTS must include at least one of: xhttp, grpc, ws, hysteria2" >&2
        echo "Current: $XRAY_PARTS" >&2
        exit 1
    fi

    case "$XRAY_HY2_MODE" in
        off|salamander|gecko) ;;
        *)
            echo "Error: XRAY_HY2_MODE must be off, salamander, or gecko (got: $XRAY_HY2_MODE)" >&2
            exit 1
            ;;
    esac

    if has_part hysteria2 && [[ "$XRAY_HY2_MODE" == "off" ]]; then
        echo "Error: hysteria2 is in XRAY_PARTS but XRAY_HY2_MODE=off (use salamander or gecko)" >&2
        exit 1
    fi

    if [[ ! "$HY2_UDP_PORT" =~ ^[0-9]+$ ]] || (( HY2_UDP_PORT < 1 || HY2_UDP_PORT > 65535 )); then
        echo "Error: HY2_UDP_PORT must be an integer 1-65535 (got: $HY2_UDP_PORT)" >&2
        exit 1
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: python3 is required to assemble JSON" >&2
        exit 1
    fi
}

# Include HY2 when explicitly listed or when mode is salamander/gecko
want_hysteria2() {
    if has_part hysteria2; then
        return 0
    fi
    case "$XRAY_HY2_MODE" in
        salamander|gecko) return 0 ;;
        *) return 1 ;;
    esac
}

hy2_fragment_rel() {
    case "$XRAY_HY2_MODE" in
        salamander) echo "${FRAGMENTS_REL}/23-inbound-hysteria2-salamander.json" ;;
        gecko) echo "${FRAGMENTS_REL}/24-inbound-hysteria2-gecko.json" ;;
        off)
            # hysteria2 in parts already rejected when mode=off
            echo "Error: internal: hy2_fragment_rel called with XRAY_HY2_MODE=off" >&2
            exit 1
            ;;
    esac
}

assemble() {
    local -a inbound_rels=()
    local hy2_mode_effective="$XRAY_HY2_MODE"

    if has_part xhttp; then
        inbound_rels+=("${FRAGMENTS_REL}/20-inbound-xhttp.json")
    fi
    if has_part grpc; then
        inbound_rels+=("${FRAGMENTS_REL}/21-inbound-grpc.json")
    fi
    if has_part ws; then
        inbound_rels+=("${FRAGMENTS_REL}/22-inbound-ws.json")
    fi

    if want_hysteria2; then
        # If hysteria2 listed with mode already validated; mode salamander|gecko also implies HY2
        if [[ "$hy2_mode_effective" == "off" ]]; then
            echo "Error: internal: HY2 requested with XRAY_HY2_MODE=off" >&2
            exit 1
        fi
        inbound_rels+=("$(hy2_fragment_rel)")
    fi

    if [[ ${#inbound_rels[@]} -eq 0 ]]; then
        echo "Error: no inbound fragments selected" >&2
        exit 1
    fi

    local f
    for f in "${FRAGMENTS_REL}/00-base.json" "${FRAGMENTS_REL}/90-tail.json" "${inbound_rels[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "Error: missing fragment $f" >&2
            exit 1
        fi
    done

    local out_json
    out_json="$(
        BASE_REL="${FRAGMENTS_REL}/00-base.json" \
        TAIL_REL="${FRAGMENTS_REL}/90-tail.json" \
        INBOUND_RELS="${inbound_rels[*]}" \
        HY2_UDP_PORT="$HY2_UDP_PORT" \
        HY2_OBFS_PASSWORD="$HY2_OBFS_PASSWORD" \
        python3 - <<'PY'
import json
import os
import sys

base_rel = os.environ["BASE_REL"]
tail_rel = os.environ["TAIL_REL"]
inbound_rels = os.environ["INBOUND_RELS"].split()
port = int(os.environ["HY2_UDP_PORT"])
password = os.environ["HY2_OBFS_PASSWORD"]

def load_fragment(path: str):
    raw = open(path, "r", encoding="utf-8").read()
    # Numeric port placeholder (unquoted in fragment)
    raw = raw.replace("__HY2_UDP_PORT__", str(port))
    # Password placeholder inside a JSON string
    raw = raw.replace("__HY2_OBFS_PASSWORD__", json.dumps(password)[1:-1])
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"Error: invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(1)

base = load_fragment(base_rel)
tail = load_fragment(tail_rel)
inbounds = [load_fragment(p) for p in inbound_rels]

if "inbounds" in base or "outbounds" in base or "routing" in base:
    print("Error: 00-base.json must not contain inbounds/outbounds/routing", file=sys.stderr)
    sys.exit(1)
if "inbounds" in tail:
    print("Error: 90-tail.json must not contain inbounds", file=sys.stderr)
    sys.exit(1)

cfg = {}
cfg.update(base)
cfg["inbounds"] = inbounds
cfg.update(tail)

print(json.dumps(cfg, indent=2, ensure_ascii=False))
PY
    )"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf '%s\n' "$out_json"
        return 0
    fi

    local out_dir
    out_dir="$(dirname "$XRAY_OUTPUT")"
    mkdir -p "$out_dir"
    # Ensure we never leave a directory where a file is expected (Docker bind-mount trap)
    if [[ -d "$XRAY_OUTPUT" ]]; then
        echo "Error: $XRAY_OUTPUT is a directory; remove it so a file can be written" >&2
        exit 1
    fi
    printf '%s\n' "$out_json" > "$XRAY_OUTPUT"
    echo "Assembled: $XRAY_OUTPUT"
    echo "  XRAY_PARTS=$XRAY_PARTS"
    echo "  XRAY_HY2_MODE=$XRAY_HY2_MODE"
    if want_hysteria2; then
        echo "  HY2_UDP_PORT=$HY2_UDP_PORT"
        echo "  HY2 included: yes (mode=${hy2_mode_effective})"
    else
        echo "  HY2 included: no"
    fi
}

load_env
parse_args "$@"
validate
assemble
