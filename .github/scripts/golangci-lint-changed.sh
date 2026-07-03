#!/usr/bin/env bash

set -euo pipefail

GITHUB_BASE_REF=${GITHUB_BASE_REF:-master}
GIT_REMOTE=${GIT_REMOTE:-origin}
GOLANGCI_LINT_BASE_REF=${GOLANGCI_LINT_BASE_REF:-}
GOLANGCI_LINT_BUILD_TAGS=${GOLANGCI_LINT_BUILD_TAGS:-synctest}
GOLANGCI_LINT_REVERSE_DEPTH=${GOLANGCI_LINT_REVERSE_DEPTH:-1}

if ! [[ "$GOLANGCI_LINT_REVERSE_DEPTH" =~ ^[0-9]+$ ]]; then
	echo "GOLANGCI_LINT_REVERSE_DEPTH must be a non-negative integer; got ${GOLANGCI_LINT_REVERSE_DEPTH}" >&2
	exit 1
fi

if [ -n "$GOLANGCI_LINT_BASE_REF" ]; then
	diff_base="$GOLANGCI_LINT_BASE_REF"
elif git rev-parse --verify --quiet "${GIT_REMOTE}/${GITHUB_BASE_REF}" >/dev/null; then
	diff_base="${GIT_REMOTE}/${GITHUB_BASE_REF}"
else
	diff_base="$GITHUB_BASE_REF"
fi

changed_files_tmp=$(mktemp)
changed_dirs_tmp=$(mktemp)
changed_pkgs_tmp=$(mktemp)
graph_tmp=$(mktemp)
selected_pkgs_tmp=$(mktemp)
frontier_pkgs_tmp=$(mktemp)
next_pkgs_tmp=$(mktemp)
lint_args_tmp=$(mktemp)
trap 'rm -f "$changed_files_tmp" "$changed_dirs_tmp" "$changed_pkgs_tmp" "$graph_tmp" "$selected_pkgs_tmp" "$frontier_pkgs_tmp" "$next_pkgs_tmp" "$lint_args_tmp"' EXIT

module_path=$(go list -m)

{
	git diff --name-only --diff-filter=ACMR "${diff_base}"...HEAD -- \
		'*.go' \
		':!vendor/**' \
		':!app/vmui/**'
	git diff --cached --name-only --diff-filter=ACMR -- \
		'*.go' \
		':!vendor/**' \
		':!app/vmui/**'
	git diff --name-only --diff-filter=ACMR -- \
		'*.go' \
		':!vendor/**' \
		':!app/vmui/**'
	git ls-files --others --exclude-standard -- \
		'*.go' \
		':!vendor/**' \
		':!app/vmui/**'
} | sort -u > "$changed_files_tmp"

if [ ! -s "$changed_files_tmp" ]; then
	echo "No changed Go files to lint."
	exit 0
fi

sed 's#[^/]*$##; s#/$##; s#^$#.#; s#^#./#; s#^\./\.$#.#' "$changed_files_tmp" | sort -u > "$changed_dirs_tmp"

changed_dirs=()
while IFS= read -r dir; do
	changed_dirs+=("$dir")
done < "$changed_dirs_tmp"
go list -tags "$GOLANGCI_LINT_BUILD_TAGS" -f '{{.ImportPath}}' "${changed_dirs[@]}" \
	| awk -v module_path="$module_path" '$0 == module_path || index($0, module_path "/") == 1' \
	| sort -u \
	> "$changed_pkgs_tmp"

if [ ! -s "$changed_pkgs_tmp" ]; then
	echo "No changed Go packages to lint."
	exit 0
fi

go list -tags "$GOLANGCI_LINT_BUILD_TAGS" \
	-f '{{.ImportPath}}{{range .Imports}} {{.}}{{end}}{{range .TestImports}} {{.}}{{end}}{{range .XTestImports}} {{.}}{{end}}' \
	./... \
	| awk -v module_path="$module_path" '$1 == module_path || index($1, module_path "/") == 1' \
	> "$graph_tmp"

cp "$changed_pkgs_tmp" "$selected_pkgs_tmp"
cp "$changed_pkgs_tmp" "$frontier_pkgs_tmp"

for _ in $(seq 1 "$GOLANGCI_LINT_REVERSE_DEPTH"); do
	awk -v selected_file="$selected_pkgs_tmp" -v frontier_file="$frontier_pkgs_tmp" '
		BEGIN {
			while ((getline pkg < selected_file) > 0) {
				selected[pkg] = 1
			}
			while ((getline pkg < frontier_file) > 0) {
				frontier[pkg] = 1
			}
		}
		{
			importer = $1
			if (selected[importer]) {
				next
			}
			for (i = 2; i <= NF; i++) {
				if (frontier[$i]) {
					print importer
					next
				}
			}
		}
	' "$graph_tmp" | sort -u > "$next_pkgs_tmp"

	if [ ! -s "$next_pkgs_tmp" ]; then
		break
	fi

	cat "$next_pkgs_tmp" >> "$selected_pkgs_tmp"
	sort -u "$selected_pkgs_tmp" -o "$selected_pkgs_tmp"
	cp "$next_pkgs_tmp" "$frontier_pkgs_tmp"
done

awk -v module_path="$module_path" '
	$0 == module_path {
		print "."
		next
	}
	index($0, module_path "/") == 1 {
		print "./" substr($0, length(module_path) + 2)
	}
' "$selected_pkgs_tmp" | sort -u > "$lint_args_tmp"

selected_pkgs=()
while IFS= read -r pkg; do
	selected_pkgs+=("$pkg")
done < "$lint_args_tmp"

echo "Changed Go files:"
sed 's/^/  /' "$changed_files_tmp"
echo "Running golangci-lint on ${#selected_pkgs[@]} package(s), reverse depth ${GOLANGCI_LINT_REVERSE_DEPTH}:"
sed 's/^/  /' "$lint_args_tmp"

golangci-lint run --build-tags "$GOLANGCI_LINT_BUILD_TAGS" --verbose --concurrency=1 "$@" "${selected_pkgs[@]}"
