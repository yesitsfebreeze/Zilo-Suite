package suite

import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

suite_lib_ext :: proc() -> string {
	when ODIN_OS == .Windows { return ".dll"   }
	when ODIN_OS == .Darwin  { return ".dylib" }
	return ".so"
}

@(private)
_is_safe_shell_token :: proc(value: string) -> bool {
	if len(value) == 0 { return false }
	for ch in value {
		if (ch >= 'a' && ch <= 'z') ||
		   (ch >= 'A' && ch <= 'Z') ||
		   (ch >= '0' && ch <= '9') {
			continue
		}
		switch ch {
		case '_', '-', '.':
		case:
			return false
		}
	}
	return true
}

@(private)
_is_safe_shell_path :: proc(value: string) -> bool {
	if len(value) == 0 { return false }
	for ch in value {
		if (ch >= 'a' && ch <= 'z') ||
		   (ch >= 'A' && ch <= 'Z') ||
		   (ch >= '0' && ch <= '9') {
			continue
		}
		switch ch {
		case ' ', '\\', '/', '_', '-', '.', ':', '+', '=', ',', '@', '(', ')', '[', ']', '{', '}':
		case:
			return false
		}
	}
	return true
}

@(private)
_quote_shell_path :: proc(value: string) -> (string, bool) {
	if !_is_safe_shell_path(value) { return "", false }
	when ODIN_OS == .Windows {
		return strings.concatenate({"\"", value, "\""}), true
	}
	if strings.contains(value, "'") { return "", false }
	return strings.concatenate({"'", value, "'"}), true
}

@(private)
_command_input_error :: proc(reason: string) -> string {
	return strings.concatenate({"invalid command input: ", reason})
}

// build_collection_flags builds the odin -collection:name="abs_path" flags string.
build_collection_flags :: proc(root_dir: string, collections: []CollectionDecl) -> (string, bool) {
	b := strings.builder_make()
	for col in collections {
		if !_is_safe_shell_token(col.name) {
			strings.builder_destroy(&b)
			return "", false
		}
		abs_path := filepath.join({root_dir, col.path})
		if clean, ok := filepath.abs(abs_path); ok {
			delete(abs_path)
			abs_path = clean
		}
		quoted_path, quoted_ok := _quote_shell_path(abs_path)
		delete(abs_path)
		if !quoted_ok {
			strings.builder_destroy(&b)
			return "", false
		}
		strings.write_string(&b, " -collection:")
		strings.write_string(&b, col.name)
		strings.write_string(&b, "=")
		strings.write_string(&b, quoted_path)
		delete(quoted_path)
	}
	return strings.to_string(b), true
}

// run_entry_check runs `odin check` against root_dir/path with the declared collections.
run_entry_check :: proc(root_dir, path: string, collections: []CollectionDecl, kind: EntryKind = .Build, nostrict: bool = false) -> CheckResult {
	joined := filepath.join({root_dir, path})
	abs_path, abs_ok := filepath.abs(joined)
	if !abs_ok { abs_path = joined } else { delete(joined) }
	defer delete(abs_path)

	quoted_path, quoted_ok := _quote_shell_path(abs_path)
	if !quoted_ok {
		return CheckResult{
			path   = path,
			output = _command_input_error("entry path"),
			passed = false,
		}
	}
	defer delete(quoted_path)

	col_flags, col_ok := build_collection_flags(root_dir, collections)
	if !col_ok {
		return CheckResult{
			path   = path,
			output = _command_input_error("collection declaration"),
			passed = false,
		}
	}
	defer delete(col_flags)

	no_entry := " -no-entry-point" if kind == .Test || kind == .Check else ""
	strict_flags := "" if nostrict else " -strict-style -vet"

	cmd := ""
	when ODIN_OS == .Windows {
		cmd = strings.concatenate({"cd /d ", quoted_path, " && odin check .", col_flags, no_entry, strict_flags, " 2>&1"})
	} else {
		cmd = strings.concatenate({"cd ", quoted_path, " && odin check .", col_flags, no_entry, strict_flags, " 2>&1"})
	}
	output, success := execute_command(cmd)
	delete(cmd)

	return CheckResult{
		path   = path,
		output = output,
		passed = success && !strings.contains(output, "error:"),
	}
}

// run_entry_test runs `odin test` against root_dir/path with the declared collections.
run_entry_test :: proc(root_dir, path: string, collections: []CollectionDecl) -> TestResult {
	joined := filepath.join({root_dir, path})
	abs_path, abs_ok := filepath.abs(joined)
	if !abs_ok { abs_path = joined } else { delete(joined) }
	defer delete(abs_path)

	quoted_path, quoted_ok := _quote_shell_path(abs_path)
	if !quoted_ok {
		return TestResult{
			path         = path,
			output       = _command_input_error("entry path"),
			passed       = false,
			total_tests  = 0,
			failed_tests = 0,
		}
	}
	defer delete(quoted_path)

	col_flags, col_ok := build_collection_flags(root_dir, collections)
	if !col_ok {
		return TestResult{
			path         = path,
			output       = _command_input_error("collection declaration"),
			passed       = false,
			total_tests  = 0,
			failed_tests = 0,
		}
	}
	defer delete(col_flags)

	cmd := ""
	when ODIN_OS == .Windows {
		cmd = strings.concatenate({"cd /d ", quoted_path, " && odin test .", col_flags, " 2>&1"})
	} else {
		cmd = strings.concatenate({"cd ", quoted_path, " && odin test .", col_flags, " 2>&1"})
	}
	output, success := execute_command(cmd)
	delete(cmd)

	total, failed_count := parse_test_counts(output)
	return TestResult{
		path         = path,
		output       = output,
		passed       = success && failed_count == 0 && !strings.contains(output, "error:"),
		total_tests  = total,
		failed_tests = failed_count,
	}
}

// run_entry_build runs `odin build` against root_dir/path placing the binary in exe_dir.
run_entry_build :: proc(root_dir, exe_dir, path, name: string, collections: []CollectionDecl, debug: bool = false) -> (bool, string) {
	joined := filepath.join({root_dir, path})
	abs_path, abs_ok := filepath.abs(joined)
	if !abs_ok { abs_path = joined } else { delete(joined) }
	defer delete(abs_path)

	ext := ".exe" when ODIN_OS == .Windows else ""
	out_file := filepath.join({exe_dir, strings.concatenate({name, ext})})
	defer delete(out_file)

	quoted_root_dir, root_ok := _quote_shell_path(root_dir)
	if !root_ok { return false, _command_input_error("root directory") }
	defer delete(quoted_root_dir)

	quoted_abs_path, abs_ok_q := _quote_shell_path(abs_path)
	if !abs_ok_q { return false, _command_input_error("entry path") }
	defer delete(quoted_abs_path)

	quoted_out_file, out_ok := _quote_shell_path(out_file)
	if !out_ok { return false, _command_input_error("output path") }
	defer delete(quoted_out_file)

	col_flags, col_ok := build_collection_flags(root_dir, collections)
	if !col_ok { return false, _command_input_error("collection declaration") }
	defer delete(col_flags)

	// Ensure output dir exists.
	os.make_directory(exe_dir)

	debug_flag := " -debug" if debug else " -o:speed"
	cmd := ""
	when ODIN_OS == .Windows {
		if !_is_safe_shell_token(name) { return false, _command_input_error("binary name") }
		cmd = strings.concatenate({
			"cd /d ", quoted_root_dir, " && taskkill /F /IM ", name, ".exe 2>nul & odin build ",
			quoted_abs_path, col_flags, " -out:", quoted_out_file, debug_flag, " 2>&1",
		})
	} else {
		cmd = strings.concatenate({
			"cd ", quoted_root_dir, " && odin build ", quoted_abs_path, col_flags,
			" -out:", quoted_out_file, debug_flag, " 2>&1",
		})
	}
	out, ok := execute_command(cmd)
	delete(cmd)
	return ok, out
}

// run_entry_shared runs `odin build -build-mode:shared` for a shared-library entry.
run_entry_shared :: proc(root_dir, exe_dir, path, name: string, collections: []CollectionDecl, debug: bool = false) -> (bool, string) {
	joined := filepath.join({root_dir, path})
	abs_path, abs_ok := filepath.abs(joined)
	if !abs_ok { abs_path = joined } else { delete(joined) }
	defer delete(abs_path)

	out_file := filepath.join({exe_dir, strings.concatenate({name, suite_lib_ext()})})
	defer delete(out_file)

	quoted_abs_path, abs_ok_q := _quote_shell_path(abs_path)
	if !abs_ok_q { return false, _command_input_error("entry path") }
	defer delete(quoted_abs_path)

	quoted_out_file, out_ok := _quote_shell_path(out_file)
	if !out_ok { return false, _command_input_error("output path") }
	defer delete(quoted_out_file)

	col_flags, col_ok := build_collection_flags(root_dir, collections)
	if !col_ok { return false, _command_input_error("collection declaration") }
	defer delete(col_flags)

	// Ensure output dir exists.
	os.make_directory(exe_dir)

	debug_flag := " -debug" if debug else ""
	cmd := ""
	when ODIN_OS == .Windows {
		cmd = strings.concatenate({
			"odin build ", quoted_abs_path, col_flags,
			" -build-mode:shared -out:", quoted_out_file, debug_flag, " 2>&1",
		})
	} else {
		cmd = strings.concatenate({
			"odin build ", quoted_abs_path, col_flags,
			" -build-mode:shared -out:", quoted_out_file, debug_flag, " 2>&1",
		})
	}
	out, ok := execute_command(cmd)
	delete(cmd)
	return ok, out
}

parse_test_counts :: proc(output: string) -> (total: int, failed: int) {
	if idx := strings.index(output, "Finished "); idx >= 0 {
		rest := output[idx + len("Finished "):]
		if sp := strings.index(rest, " tests"); sp >= 0 {
			total, _ = strconv.parse_int(rest[:sp])
		}
	}
	if idx := strings.index(output, " tests failed"); idx >= 0 {
		start := idx
		for start > 0 && output[start-1] >= '0' && output[start-1] <= '9' {
			start -= 1
		}
		failed, _ = strconv.parse_int(output[start:idx])
	}
	return
}
