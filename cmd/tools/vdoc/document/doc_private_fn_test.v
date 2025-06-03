module document

import os

fn testsuite_begin() {
	os.chdir(@VMODROOT) or {}
	eprintln('>> @VMODROOT: ' + @VMODROOT)
}

fn test_get_parent_mod_on_root_folder() {
	// TODO: add an equivalent windows check for c:\
	$if !windows {
		assert '---' == get_parent_mod('/') or {
			assert err.msg() == 'root folder reached'
			'---'
		}
	}
}

fn test_get_parent_mod_current_folder() {
	// TODO: this should may be return '' reliably on windows too:
	// assert '' == get_parent_mod('.') or {
	//	assert err.msg() == 'No V files found.'
	//	'---'
	// }
}

fn test_get_parent_mod_on_temp_dir() {
	// TODO: fix this on windows
	$if !windows {
		assert get_parent_mod(os.temp_dir())? == ''
	}
}

// vlang/cmd/tools/vdoc
// vlang/cmd/tools/vdoc/vlib/v

fn test_get_parent_mod_normal_cases() {
	v_root := os.dir(@VEXE)
	assert '---' == get_parent_mod(os.join_path(v_root, 'vlib/v')) or {
		assert err.msg() == 'No V files found.'
		'---'
	}
	assert get_parent_mod(os.join_path(v_root, 'vlib', 'v', 'token'))? == 'v'
	assert get_parent_mod(os.join_path(v_root, 'vlib', 'os', 'os.v'))? == 'os'
	assert get_parent_mod(os.join_path(v_root, 'cmd'))? == ''
	assert get_parent_mod(os.join_path(v_root, 'cmd', 'tools', 'modules', 'testing', 'common.v'))? == 'testing'
}
