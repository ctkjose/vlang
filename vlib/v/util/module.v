module util

// 2022-01-30 TODO: this whole file should not exist :-|. It should just use the existing `v.vmod` instead,
// 2022-01-30 that already does handle v.mod lookup properly, stopping at .git folders, supporting `.v.mod.stop` etc.
import os
import v.pref

const place_is_std = 1
const place_is_prj = 2

const mod_file_stop_paths = ['.git', '.hg', '.svn', '.v.mod.stop']

@[if trace_util_qualify ?]
fn trace_qualify(callfn string, mod string, base_path string, action string, detail string) {
	eprintln('> ${callfn:-15}: ${mod:-18} | base_path: ${base_path} | ${action:-14} | ${detail}')
}

// mod_resolve() resolves a module name to its folder, locates a
// corresponding v.mod file and computes a qualified module name
//
// The qualified module name is the path segments up to a root folder.
// Where a root folder is @vlib, @vmodules, and the folder with the file
// getting compiled.
//
// returns (qualified_mod_name, mod_directory, vmod_file)
//
pub fn resolve_module(pref_ &pref.Preferences, mod string, file_path_in string, is_module bool) (string, string, string) {
	mut curr_dir := os.getwd()
	mut vlib_path := pref_.vlib

	// we use pref_.path for the project root
	mut prj_path := if pref_.path.len > 0 && pref_.path != '-' {
		pref_.path
	} else {
		// Hack to support relative modules
		curr_dir
	}

	prj_path = os.real_path(prj_path)
	mut prj_dir := if !os.is_dir(prj_path) {
		os.dir(prj_path)
	} else {
		prj_path
	}

	mut file_path := os.real_path(os.dir(file_path_in))
	mut file_dir := if !os.is_dir(file_path) {
		os.dir(file_path)
	} else {
		file_path
	}
	mut file_parent_dir := os.dir(file_dir)

	//@ctk: Should we add @vlib and @vmodules if not in lookup_path?
	// Look in standard locations...
	mut std_search_paths := pref_.lookup_path.clone()

	// Paths where we stop searching
	mut stop_roots := std_search_paths.clone()
	stop_roots << prj_dir
	// Look relative to project or parsed file
	mut prj_search_paths := [file_dir, file_parent_dir]

	if prj_dir != file_dir {
		prj_search_paths << prj_dir
	}

	// std_search_paths = std_search_paths.filter( it == pref_.vlib )

	if os.exists(os.join_path(file_dir, 'modules')) {
		prj_search_paths << os.join_path(file_dir, 'modules')
	}

	mut all_search_paths := std_search_paths.clone()
	all_search_paths << prj_search_paths

	mut mod_root := ''

	mut vmod_file := ''
	mut mod_dir := ''

	mut mod_name := mod
	mod_path := mod.replace('.', os.path_separator)

	mut mod_idx := 0 // track

	// println('resolve_module(${mod}, ${file_path}, ${is_module})')
	// println(all_search_paths)

	trace_qualify(@FN, mod, file_path, 'in', all_search_paths.join('; '))
	trace_qualify(@FN, mod, file_path, 'prj.path', prj_dir)
	if is_module {
		mod_dir = file_dir
		mod_root = file_parent_dir

		if mod == 'main' {
			return mod, mod_dir, ''
		}

		trace_qualify(@FN, mod, file_path, 'dir', mod_dir)

		stop_roots << file_parent_dir
	} else {
		for search_path in all_search_paths {
			mut try_path := os.join_path_single(search_path, mod_path)

			trace_qualify(@FN, mod, file_path, 'try', try_path)

			if !os.is_dir(try_path) || !os.exists(try_path) {
				continue
			}
			// println(' resolve_module(${mod}) found=${search_path}')

			mod_dir = try_path
			mod_root = search_path // what root we found it
			trace_qualify(@FN, mod, file_path, 'dir', try_path)
			break
		}
	}

	if mod_dir.len == 0 {
		return mod, '', ''
	}

	in_vlib := if mod_root.len >= vlib_path.len && mod_root[0..vlib_path.len] == vlib_path {
		true
	} else {
		false
	}

	if in_vlib {
		// force relative to vlib
		mod_name = mod_dir[vlib_path.len + 1..]
	} else {
		mod_name = mod_dir[mod_root.len + 1..]
	}

	// QMN is always relative to search_path
	mod_name = mod_name.replace(os.path_separator, '.')
	trace_qualify(@FN, mod, file_path, 'qualified.name', mod_name)

	if in_vlib {
		// don't look for v.mod
		return mod_name, mod_dir, ''
	}
	// Find closest v.mod
	path_parts := mod_dir.split(os.path_separator)

	// Find the best root
	mut stop_root := file_parent_dir
	for a_root_path in stop_roots {
		if mod_dir.len >= a_root_path.len && mod_dir[0..a_root_path.len] == a_root_path {
			stop_root = a_root_path
			break
		}
	}

	trace_qualify(@FN, mod, file_path, 'stop.root', stop_root)

	for i := path_parts.len; i > 0; i-- {
		try_path := path_parts[0..i].join(os.path_separator)
		mod_idx = i - 1

		mut reched_root := false

		if stop_root == try_path {
			mod_idx += 1

			reched_root = true
		}

		if files := os.ls(try_path) {
			if 'v.mod' in files {
				vmod_file = os.join_path_single(try_path, 'v.mod')
				trace_qualify(@FN, mod, file_path, 'v.mod', vmod_file)
				reched_root = true

				// allow Go style src folder...
				if os.base(mod_dir) == 'src' {
					trace_qualify(@FN, mod, file_path, 'go.hack', 'using repo.src')
					reched_root = false

					mod_name = path_parts#[mod_idx..-1].join('.')
					trace_qualify(@FN, mod, file_path, 'qualified.name', mod_name)
					break
				}
			} else {
				for s_dir in mod_file_stop_paths {
					if s_dir in files {
						trace_qualify(@FN, mod, file_path, 'stop', '${s_dir} at ${try_path}')
						reched_root = true
						break
					}
				}
			}
		}

		if reched_root {
			// println('p=${path_parts#[..mod_idx+1]}=${try_path}')

			if path_parts#[mod_idx..].join('.') != mod_dir {
				// we stopped at a diff folder, change QMN
				mod_name = path_parts#[mod_idx..].join('.')
				trace_qualify(@FN, mod, file_path, 'qualified.name', mod_name)
			}

			break
		}
	}

	return mod_name, mod_dir, vmod_file
}

// 2022-01-30 qualify_import - used by V's parser, to find the full module name of import statements
// 2022-01-30 i.e. when parsing `import automaton` inside a .v file in examples/game_of_life/life_gg.v
// 2022-01-30 it returns just 'automaton'
// 2022-01-30 TODO: this seems to always just return `mod` itself, for modules inside the V main folder.
// 2022-01-30 It does also return `mod` itself, for stuff installed in ~/.vmodules like `vls` but for
// 2022-01-30 other reasons (see res 2 below).
pub fn qualify_import(pref_ &pref.Preferences, mod string, file_path string) string {
	// comments are from workdir: /v/vls

	trace_qualify(@FN, mod, file_path, 'import.resolve', '')

	mut mod_paths := pref_.lookup_path.clone()
	mod_paths << os.vmodules_paths()
	mod_path := mod.replace('.', os.path_separator)
	for search_path in mod_paths {
		try_path := os.join_path_single(search_path, mod_path)
		if os.is_dir(try_path) {
			if m1 := mod_path_to_full_name(pref_, mod, try_path) {
				trace_qualify(@FN, mod, file_path, 'dir', try_path)
				trace_qualify(@FN, mod, file_path, 'qualified.name', m1)
				// >  qualify_import: term | file_path: /v/vls/server/diagnostics.v | => import_res 1: term  ; /v/cleanv/vlib/term
				return m1
			}
		}
	}
	if m1 := mod_path_to_full_name(pref_, mod, file_path) {
		trace_qualify(@FN, mod, file_path, 'dir', file_path)
		trace_qualify(@FN, mod, file_path, 'qualified.name', m1)

		// >  qualify_module: analyzer           | file_path: /v/vls/analyzer/store.v  | =>   module_res 2: analyzer           ; clean_file_path - getwd == mod
		// >  qualify_import: analyzer.depgraph  | file_path: /v/vls/analyzer/store.v  | =>   import_res 2: analyzer.depgraph  ; /v/vls/analyzer/store.v
		// >  qualify_import: tree_sitter        | file_path: /v/vls/analyzer/store.v  | =>   import_res 2: tree_sitter        ; /v/vls/analyzer/store.v
		// >  qualify_import: tree_sitter_v      | file_path: /v/vls/analyzer/store.v  | =>   import_res 1: tree_sitter_v      ; ~/.vmodules/tree_sitter_v
		// >  qualify_import: jsonrpc            | file_path: /v/vls/server/features.v | =>   import_res 2: jsonrpc            ; /v/vls/server/features.v
		return m1
	}
	trace_qualify(@FN, mod, file_path, 'qualified.name', mod)
	trace_qualify(@FN, mod, file_path, 'dir', mod_path)

	// >  qualify_import: server | file_path: cmd/vls/host.v | =>   import_res 3: server ; ---
	// >  qualify_import: cli    | file_path: cmd/vls/main.v | =>   import_res 1: cli    ; /v/cleanv/vlib/cli
	// >  qualify_import: server | file_path: cmd/vls/main.v | =>   import_res 3: server ; ---
	// >  qualify_import: os     | file_path: cmd/vls/main.v | =>   import_res 1: os     ; /v/cleanv/vlib/os
	return mod
}

// 2022-01-30 qualify_module - used by V's parser to find the full module name
// 2022-01-30 i.e. when parsing `module textscanner`, inside vlib/strings/textscanner/textscanner.v
// 2022-01-30 it will return `strings.textscanner`
pub fn qualify_module(pref_ &pref.Preferences, mod string, file_path string) string {
	if mod == 'main' {
		trace_qualify(@FN, mod, file_path, 'qualified.name', mod)
		return mod
	}
	clean_file_path := file_path.all_before_last(os.path_separator)
	// relative module (relative to working directory)
	// TODO: find most stable solution & test with -usecache
	//
	// TODO: 2022-01-30: Using os.getwd() here does not seem right *at all* imho.
	// TODO: 2022-01-30: That makes lookup dependent on fragile environment factors.
	// TODO: 2022-01-30: The lookup should be relative to the folder, in which the current file is,
	// TODO: 2022-01-30: *NOT* to the working folder of the compiler, which can change easily.
	if clean_file_path.replace(os.getwd() + os.path_separator, '') == mod {
		trace_qualify(@FN, mod, file_path, 'qualified.name', '${mod},clean_file_path - getwd == mod, clean_file_path: ${clean_file_path}')
		return mod
	}
	if m1 := mod_path_to_full_name(pref_, mod, clean_file_path) {
		trace_qualify(@FN, mod, file_path, 'module_res 3', '${m1} == f(${clean_file_path})')
		// >  qualify_module: net  | file_path: /v/cleanv/vlib/net/util.v     | =>   module_res 3: net     ; m1 == f(/v/cleanv/vlib/net)
		// >  qualify_module: term | file_path: /v/cleanv/vlib/term/control.v | =>   module_res 3: term    ; m1 == f(/v/cleanv/vlib/term)
		// >  qualify_module: log  | file_path: /v/vls/lsp/log/log.v          | =>   module_res 3: lsp.log ; m1 == f(/v/vls/lsp/log)

		// zzz BUG: when ../v.mod exists above V root folder:
		// zzz >  qualify_module: help | file_path: /v/cleanv/cmd/v/help/help.v   | =>   module_res 3: v.cmd.v.help  ; m1 == f(/v/cleanv/cmd/v/help)
		return m1
	}
	// zzzzzzz WORKING, when there is NO ../v.mod:
	// zzzzzzz >  qualify_module: help | file_path: /v/cleanv/cmd/v/help/help.v   | =>   module_res 4: help          ; ---, clean_file_path: /v/cleanv/cmd/v/help
	trace_qualify(@FN, mod, file_path, 'module_res 4', '${mod} ---, clean_file_path: ${clean_file_path}')
	return mod
}

// TODO:
// * properly define module location / v.mod rules
// * if possible split this function in two, one which gets the
// parent module path and another which turns it into the full name
// * create shared logic between these fns and builder.find_module_path
// 2022-01-30 TODO: the reliance on os.path_separator here, is also a potential problem.
// 2022-01-30 On windows that leads to:
// 2022-01-30 `v path/subfolder/` behaving very differently than `v path\subfolder\`
// 2022-01-30 (see daa5be4, that skips checking `vlib/v/checker/tests/modules/deprecated_module`
// 2022-01-30 just on windows, because while `vlib\v\checker\tests\modules\deprecated_module` works,
// 2022-01-30 it leads to path differences, and the / version on windows triggers a module lookip bug,
// 2022-01-30 leading to completely different errors)
fn mod_path_to_full_name(pref_ &pref.Preferences, mod string, path string) !string {
	// println('mod_path_to_full_name(${mod}, ${path})') //@CTK
	// TODO: explore using `pref.lookup_path` & `os.vmodules_paths()`
	// absolute paths instead of 'vlib' & '.vmodules'
	mut vmod_folders := ['vlib', '.vmodules', 'modules']
	bases := pref_.lookup_path.map(os.base(it))
	for base in bases {
		if base !in vmod_folders {
			vmod_folders << base
		}
	}
	mut in_vmod_path := false
	parts := path.split(os.path_separator)
	for vmod_folder in vmod_folders {
		if vmod_folder in parts {
			in_vmod_path = true
			break
		}
	}
	path_parts := path.split(os.path_separator)
	mod_path := mod.replace('.', os.path_separator)
	// go back through each parent in path_parts and join with `mod_path` to see the dir exists
	for i := path_parts.len - 1; i > 0; i-- {
		try_path := os.join_path_single(path_parts[0..i].join(os.path_separator), mod_path)
		// println('mod_path_to_full_name(${mod}) try=${try_path}') //@CTK
		// found module path
		if os.is_dir(try_path) {
			// we know we are in one of the `vmod_folders`
			if in_vmod_path {
				// so we can work our way backwards until we reach a vmod folder
				for j := i; j >= 0; j-- {
					path_part := path_parts[j]
					// we reached a vmod folder
					if path_part in vmod_folders {
						mod_full_name := try_path.split(os.path_separator)[j + 1..].join('.')
						return mod_full_name
					}
				}
				// not in one of the `vmod_folders` so work backwards through each parent
				// looking for for a `v.mod` file and break at the first path without it
			} else {
				mut try_path_parts := try_path.split(os.path_separator)
				// last index in try_path_parts that contains a `v.mod`
				mut last_v_mod := -1
				for j := try_path_parts.len; j > 0; j-- {
					parent := try_path_parts[0..j].join(os.path_separator)
					if ls := os.ls(parent) {
						// currently CI clones some modules into the v repo to test, the condition
						// after `'v.mod' in ls` can be removed once a proper solution is added
						if 'v.mod' in ls
							&& (try_path_parts.len > i && try_path_parts[i] != 'v' && 'vlib' !in ls) {
							last_v_mod = j
							println('mod_path_to_full_name(${mod}) found v.mod[${j}] in ${parent}')
							break
						}
						continue
					}
					break
				}
				if last_v_mod > -1 {
					mod_full_name := try_path_parts[last_v_mod..].join('.')
					println('mod_path_to_full_name(${mod}) index=${last_v_mod}=${mod_full_name}')

					return if mod_full_name.len < mod.len { mod } else { mod_full_name }
				}
			}
		}
	}
	if os.is_abs_path(pref_.path) && os.is_abs_path(path) && os.is_dir(path) { // && path.contains(mod )
		rel_mod_path := path.replace(pref_.path.all_before_last(os.path_separator) +
			os.path_separator, '')
		if rel_mod_path != path {
			full_mod_name := rel_mod_path.replace(os.path_separator, '.')
			return full_mod_name
		}
	}
	return error('module not found')
}
