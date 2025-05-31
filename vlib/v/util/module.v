module util

// 2022-01-30 TODO: this whole file should not exist :-|. It should just use the existing `v.vmod` instead,
// 2022-01-30 that already does handle v.mod lookup properly, stopping at .git folders, supporting `.v.mod.stop` etc.
import os
import v.pref

const place_is_std = 1
const place_is_prj = 2

const mod_file_stop_paths = ['v.mod', '.git', '.hg', '.svn', '.v.mod.stop']

@[if trace_util_qualify ?]
fn trace_qualify(callfn string, mod string, base_path string, action string, detail string) {
	eprintln('> ${callfn:-15}: ${mod:-18} | base_path: ${base_path} | ${action:-14} | ${detail}')
}

@[if debug_mod_resolve ?]
fn debug_qualify(is_verbose bool, mod string, detail string) {
	if !is_verbose {
		return
	}
	eprintln('> module_resolve( ${mod} ) ${detail}')
}

const qmn_internal_cache = qmn_init_cache()

@[heap]
pub struct ModuleQMNCache {
mut:
	items map[string][]string
}

fn qmn_init_cache() &ModuleQMNCache {
	return &ModuleQMNCache{}
}

fn qmn_get_cache() &ModuleQMNCache {
	return qmn_internal_cache
}

// mod_resolve() resolves a module name to its folder, locates a
// corresponding v.mod file and computes a qualified module name
//
// The qualified module name is the path segments up to a root folder.
// Where a root folder is @vlib, @vmodules, and the folder with the file
// getting compiled.
//
// returns (qualified_mod_name, mod_directory, mod_vmod_file)
//
pub fn resolve_module(pref_ &pref.Preferences, mod string, file_path_in string, is_module bool) (string, string, string) {
	mut curr_dir := os.getwd()
	// mut vlib_path := pref_.vlib

	mut mod_anchor := ''
	mut mod_vmod_file := ''
	mut mod_dir := ''

	mut mod_name := mod
	mut mod_segs := mod.split('.')

	mut cache := qmn_get_cache()

	//@ctk: Should we add @vlib and @vmodules if not in lookup_path?
	// Look in standard root locations...
	mut root_search_paths := pref_.lookup_path.clone()

	// <prj_path> is the project root as provided by pref_.path
	mut prj_path := if pref_.path.len > 0 && pref_.path != '-' {
		pref_.path
	} else {
		// Hack to support relative modules, specially in REPL
		curr_dir
	}

	prj_path = os.real_path(prj_path)
	mut prj_dir := if !os.is_dir(prj_path) {
		os.dir(prj_path)
	} else {
		prj_path
	}

	if prj_path#[-1..] == os.path_separator {
		prj_path = prj_path#[-1..]
	}

	mut file_path := os.real_path(file_path_in)
	mut file_dir := if !os.is_dir(file_path) {
		os.dir(file_path)
	} else {
		file_path
	}

	// Go Quirk
	if os.base(file_dir) == 'src' {
		// Convert "a/path/to/prj/src" => "a/path/to/prj/"
		// To be able to find sibling modules "a/path/to/prj/mod1" and "a/path/to/prj/modules/mod1"    f
		file_dir = os.dir(file_dir)
	}

	// Look relative to project or parsed file
	mut prj_search_paths := [prj_dir]

	if os.exists(os.join_path(prj_dir, 'modules')) {
		prj_search_paths << os.join_path(prj_dir, 'modules')
	}

	// RULE: Relative to file parsed...
	prj_search_paths << file_dir

	// RULE: Allow <rel_file_dir>/modules
	if prj_dir != file_dir {
		if os.exists(os.join_path(file_dir, 'modules')) {
			prj_search_paths << os.join_path(file_dir, 'modules')
		}
	}

	// RULE: Allow sibling resolution: "vlib/a/b/file.v" using "import c" instead of "import a.c"
	// expects it to resolve to "vlib/a/c". This was the case of `vlib/v/type_resolver/type_resolver.v`.
	///prj_search_paths << os.dir(file_dir) //@CTK disabled per discussion
	// println(prj_search_paths)

	mut all_search_paths := root_search_paths.clone()
	all_search_paths << prj_search_paths

	// Find the root path to use
	for a_path in root_search_paths {
		// Im running a prj inside a root folder, then we can have a sibling
		if prj_dir.starts_with(a_path) {
			prj_search_paths << os.dir(prj_dir)
			break
		}
	}
	if is_module {
		mod_dir = file_dir
		mod_anchor = os.dir(file_dir)

		// debug_qualify(pref_.is_verbose, mod, '@module = true')

		if mod == 'main' || mod != os.base(file_dir) {
			if pref_.is_verbose {
				eprintln('> module_resolve( ${mod} ) qmn "${mod}" at "${mod_dir}", v.mod="${mod_vmod_file}"')
			}
			return mod, mod_dir, ''
		}

		for search_path in all_search_paths {
			if mod_dir.starts_with(search_path) {
				mod_anchor = search_path
				break
			}
		}
	} else {
		mut p_root_try := ''
		mut p := ''

		main_loop: for a_path in all_search_paths {
			p_root_try = a_path
			for i := 0; i < mod_segs.len; i++ {
				p = os.join_path(p_root_try, mod_segs[i])
				debug_qualify(pref_.is_verbose, mod, 'd_try[${i}][${mod_segs[i]}] "${a_path}" "${p}"')

				if !os.exists(p) {
					// Try a modules folder...
					p = os.join_path(p_root_try, 'modules', mod_segs[i])
					debug_qualify(pref_.is_verbose, mod, 'd_try[${i}] "${a_path}" "${p}"')
					if !os.exists(p) {
						break
					}
				}
				p_root_try = p
				if i == mod_segs.len - 1 {
					debug_qualify(pref_.is_verbose, mod, 'd_try_matched "${p_root_try}"')
					mod_dir = p_root_try
					mod_anchor = a_path
					break main_loop
				}
			}
		}
	}

	if mod_dir.len == 0 && pref_.is_verbose {
		debug_qualify(pref_.is_verbose, mod, 'Error not found...')
	}

	if mod_dir in cache.items {
		m := cache.items[mod_dir] or { ['', '', ''] }

		if pref_.is_verbose {
			eprintln('> module_resolve( ${mod} ) qmn "${m[0]}" at "${m[1]}", v.mod="${m[2]}" (cache)')
		}

		return m[0], m[1], m[2]
	}

	if pref_.is_verbose {
		eprintln('> module_resolve( ${mod} ) from "${file_path_in}"')
		debug_qualify(pref_.is_verbose, mod, 'pref.path = "${prj_dir}"')

		eprintln('> module_resolve(${mod}, ${file_path}) mod.dir = "${mod_dir}"')
	}

	if mod_dir.len == 0 {
		if pref_.is_verbose {
			eprintln('> module_resolve( ${mod} ) qmn "${mod}" at "${mod_dir}", v.mod="${mod_vmod_file}"')
		}

		return mod, '', ''
	}
	debug_qualify(pref_.is_verbose, mod, 'anchor = "${mod_anchor}"')

	// Fine tune the anchor
	if mod_dir.starts_with(prj_dir) {
		// we are executing something inside one of the standard paths
		// change context to the project
		// mod_anchor = prj_dir
	}

	// mut in_std_path := true
	mut prj_anchor := ''

	if mod_anchor !in root_search_paths && mod_anchor != prj_dir {
		// include anchor folder
		// in_std_path = false
		prj_anchor = os.base(mod_anchor)

		// move anchor up, to make sure we include base
		mod_anchor = mod_anchor.substr(0, mod_anchor.len - (prj_anchor.len + 1))
	}

	debug_qualify(pref_.is_verbose, mod, 'anchor = "${mod_anchor}"')

	// QMN is always anchored...
	///mut anchored_path := mod_dir.replace(mod_anchor, '')
	///debug_qualify(pref_.is_verbose, mod, 'anchored_path = "${anchored_path}"')

	// QMN will only change if a stop location is found somewhere inside mod_anchor
	// only search from current anchor, reduce the number of segments
	path_parts := mod_dir.replace(mod_anchor, '').split(os.path_separator)
	mut anchor_idx := 1
	for i := path_parts.len - 1; i > 0; i-- {
		anchor_idx = i

		stop_location := mod_anchor + os.path_separator + path_parts[1..i +
			1].join(os.path_separator)

		if path_parts[i] == 'modules' {
			// anchor_idx += 1 // rewind
			// debug_qualify(pref_.is_verbose, mod, 'anchored at "${stop_location}"')
			// break
		}

		mod_vmod_file = os.join_path_single(stop_location, 'v.mod')
		if os.exists(mod_vmod_file) {
			debug_qualify(pref_.is_verbose, mod, 'anchored at "${stop_location}"')
			break
		} else {
			mod_vmod_file = ''
		}
	}

	mod_name = path_parts[anchor_idx..].filter(it != 'modules').join('.')
	if mod_name.len > 0 && mod_name[0..1] == '.' {
		mod_name[1..]
	}

	// mod_name = mod_name.replace('.modules.', '.')
	debug_qualify(pref_.is_verbose, mod, 'qmn[] = "${mod_name}"')

	if pref_.is_verbose {
		eprintln('> module_resolve( ${mod} ) qmn "${mod_name}" at "${mod_dir}", v.mod="${mod_vmod_file}')
	}

	cache.items[mod_dir] = [mod_name, mod_dir, mod_vmod_file]
	return mod_name, mod_dir, mod_vmod_file
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
