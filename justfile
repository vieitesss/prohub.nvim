plenary_ref := "74b06c6c75e4eeb3108ec01852001636d85a932b"
plenary_url := "https://github.com/nvim-lua/plenary.nvim"

_default:
	just -l

# Run the plenary test suite headlessly. Pass spec paths, relative to this
# directory, to run only those: just test tests/functional/base_spec.lua
test *paths:
	#!/usr/bin/env bash
	set -euo pipefail
	cd "{{ justfile_directory() }}"

	# just passes the arguments of a shebang recipe through interpolation.
	set -- {{paths}}

	plenary_path="{{ justfile_directory() }}/plenary.nvim"

	if ! test -d "${plenary_path}"; then
		git clone {{ plenary_url }} "${plenary_path}"
	fi

	git -C "${plenary_path}" checkout "{{ plenary_ref }}"

	minimal_init="{{ justfile_directory() }}/tests/minimal_init.lua"
	if [ "$#" -eq 0 ]; then
		# The harness runs every spec file in its own editor, in parallel.
		nvim --headless --noplugin \
			-u "${minimal_init}" \
			-c "lua require('plenary.test_harness').test_directory('tests', { minimal_init = '${minimal_init}' })"
		exit
	fi

	# One editor per spec file, and every file runs even after a failure. The
	# harness runs the file in a child editor and kills it when it outlasts the
	# timeout of the harness, so a spec that blocks fails instead of hanging.
	status=0
	for path in "$@"; do
		nvim --headless --noplugin \
			-u "${minimal_init}" \
			-c "lua require('plenary.test_harness').test_directory('${path}', { minimal_init = '${minimal_init}', sequential = true })" \
			|| status=$?
	done
	exit "${status}"

# Format the Lua sources with stylua.
format:
	stylua .

# Fail when the Lua sources are not formatted.
format-check:
	stylua --check .
