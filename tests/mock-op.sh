#!/usr/bin/env bash
# Mock 1Password CLI for testing use() without hitting the real API.
# Place this earlier in PATH to intercept `op` calls.
#
# Supports:
#   op read <ref>                  — returns mock secret from MOCK_OP_SECRETS
#   op inject                      — reads stdin, resolves op:// refs inline
#   op run --env-file=<f> -- <cmd> — resolves op:// refs in env file, exports them, runs <cmd>
#
# Configuration:
#   MOCK_OP_SECRETS_FILE — file with "op://ref=value" lines (one per line)
#   MOCK_OP_LOG          — if set, append each call to this file for verification

if [ -n "${MOCK_OP_LOG:-}" ]; then
    echo "op $*" >> "$MOCK_OP_LOG"
fi

case "${1:-}" in
    read)
        ref="${2:-}"
        # Look up the ref in the mock secrets file (one "ref=value" per line).
        # Match the ref as a literal prefix and strip it with parameter
        # expansion — the ref itself may contain "=" (e.g. ?ssh-format=openssh),
        # so splitting the line on the first "=" would truncate wrongly.
        if [ -f "${MOCK_OP_SECRETS_FILE:-}" ]; then
            value=""
            while IFS= read -r secret_line; do
                case "$secret_line" in
                    "${ref}="*) value="${secret_line#"${ref}"=}"; break ;;
                esac
            done < "$MOCK_OP_SECRETS_FILE"
            if [ -n "$value" ]; then
                # "file:<path>" values return the file's contents — lets tests
                # serve multi-line secrets (e.g. SSH private keys) that can't
                # live on one line of the secrets file.
                case "$value" in
                    file:*) cat "${value#file:}" ;;
                    *)      echo "$value" ;;
                esac
                exit 0
            fi
        fi
        echo "[ERROR] mock-op: secret not found: $ref" >&2
        exit 1
        ;;
    inject)
        # Read stdin, resolve op:// references inline
        while IFS= read -r line; do
            if [[ "$line" == *op://* ]]; then
                # Extract the op:// ref from the value side of KEY=op://...
                key="${line%%=*}"
                val="${line#*=}"
                if [ -f "${MOCK_OP_SECRETS_FILE:-}" ]; then
                    resolved=$(grep "^${val}=" "$MOCK_OP_SECRETS_FILE" | head -1 | cut -d= -f2-)
                    if [ -n "$resolved" ]; then
                        echo "${key}=${resolved}"
                    else
                        echo "[ERROR] mock-op: unresolved ref: $val" >&2
                        exit 1
                    fi
                fi
            else
                echo "$line"
            fi
        done
        ;;
    run)
        # Parse: op run --env-file=<file> -- <cmd...>
        env_file=""
        shift # consume "run"
        while [ $# -gt 0 ]; do
            case "$1" in
                --env-file=*) env_file="${1#--env-file=}"; shift ;;
                --env-file)   env_file="$2"; shift 2 ;;
                --)           shift; break ;;
                *)            shift ;;
            esac
        done

        # Resolve op:// references in env file and export as real env vars
        if [ -n "$env_file" ] && [ -f "$env_file" ]; then
            while IFS='=' read -r key val; do
                # Skip comments and empty lines
                [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
                if [[ "$val" == op://* ]]; then
                    # Resolve via mock secrets file
                    if [ -f "${MOCK_OP_SECRETS_FILE:-}" ]; then
                        resolved=$(grep "^${val}=" "$MOCK_OP_SECRETS_FILE" | head -1 | cut -d= -f2-)
                        if [ -n "$resolved" ]; then
                            export "$key=$resolved"
                        else
                            echo "[ERROR] mock-op: unresolved ref in env file: $val" >&2
                            exit 1
                        fi
                    fi
                else
                    # Plain value, export as-is
                    export "$key=$val"
                fi
            done < "$env_file"
        fi

        # Execute the command
        exec "$@"
        ;;
    --version)
        echo "mock-op 0.0.0 (test)"
        ;;
    *)
        echo "[ERROR] mock-op: unsupported command: $*" >&2
        exit 1
        ;;
esac
