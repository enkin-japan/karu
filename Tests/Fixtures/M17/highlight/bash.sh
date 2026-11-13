#!/usr/bin/env bash
# deploy.sh — release helper with heredocs and expansions.
# A comment with "quotes" and $(not a substitution) and a 'single quote.
set -euo pipefail

APP_NAME="${APP_NAME:-karu}"
VERSION="$(git describe --tags --always 2>/dev/null || echo "0.0.0")"
BUILD_DIR="${BUILD_DIR:-$(pwd)/build}"
TARGETS=(macos-arm64 macos-x86_64 "linux amd64")
COUNT=${#TARGETS[@]}
HALF=$(( COUNT / 2 ))
URL="https://example.com/#anchor"   # the # inside quotes is not a comment
echo "Building ${APP_NAME} v${VERSION} for ${COUNT} targets (half=${HALF})"

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] <target>

Targets: ${TARGETS[*]}
Version: $VERSION   # not a comment inside an unquoted heredoc
Today:   $(date +%Y-%m-%d)
EOF
}

write_config() {
	cat <<-EOF
		# <<-EOF strips leading tabs; this line is heredoc body, not a comment
		name = "${APP_NAME}"
		version = $VERSION
		build_dir = ${BUILD_DIR}
	EOF
}

literal_script() {
    cat <<'EOF'
#!/bin/sh
# Quoted delimiter: $HOME and $(whoami) are NOT expanded here.
echo "literal ${VAR:-default}"
EOF
}

double_quoted_delim() {
    cat <<"END_OF_NOTES"
Notes for $APP_NAME stay literal as well; "quotes" and 'apostrophes' too.
END_OF_NOTES
}

multi_line_string="first line
second line with $APP_NAME and \"escaped quotes\"
third line # not a comment"

nested="$(echo "outer $(echo "inner ${APP_NAME^^}")")"
legacy=`echo backticks $APP_NAME`
trimmed="${VERSION%%-*}"
replaced="${URL//\//_}"

for target in "${TARGETS[@]}"; do
    case "$target" in
        macos-*) echo "mac: ${target#macos-}" ;;
        *) echo "other: $target" ;;
    esac
done

if [[ "${1:-}" == "--dry-run" ]]; then
    usage
    literal_script
    double_quoted_delim
else
    mkdir -p "$BUILD_DIR" && write_config > "$BUILD_DIR/release.conf"
fi
printf '%s\n' "$multi_line_string" "$nested" "$legacy" "$trimmed" "$replaced"
