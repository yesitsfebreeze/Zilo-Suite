package suite

import "core:fmt"
import "core:strings"

when ODIN_OS == .Windows {
	foreign import libc "system:libcmt.lib"
} else {
	foreign import libc "system:c"
}

foreign libc {
	_popen  :: proc(command: cstring, mode: cstring) -> rawptr ---
	_pclose :: proc(stream: rawptr) -> i32 ---
	popen   :: proc(command: cstring, mode: cstring) -> rawptr ---
	pclose  :: proc(stream: rawptr) -> i32 ---
	fgets   :: proc(str: [^]u8, n: i32, stream: rawptr) -> [^]u8 ---
	feof    :: proc(stream: rawptr) -> i32 ---
}

@(private="file")
_has_forbidden_command_chars :: proc(cmd: string) -> bool {
	for ch in cmd {
		if ch == '\n' || ch == '\r' || ch == 0 { return true }
	}
	return false
}

execute_command :: proc(cmd: string) -> (output: string, success: bool) {
	if _has_forbidden_command_chars(cmd) {
		return strings.clone("[command failed: invalid command input]"), false
	}
	when ODIN_OS == .Windows {
		return execute_command_windows(cmd)
	} else {
		return execute_command_unix(cmd)
	}
}

@(private="file")
_finalize_command_result :: proc(cmd, output: string, exit_code: i32) -> (string, bool) {
	if exit_code == 0 {
		return output, true
	}

	b := strings.builder_make()
	if len(output) > 0 {
		strings.write_string(&b, output)
		if output[len(output)-1] != '\n' {
			strings.write_string(&b, "\n")
		}
		delete(output)
	}
	fmt.sbprintf(&b, "[command failed: exit=%d]\n%s\n", exit_code, cmd)
	return strings.to_string(b), false
}

execute_command_windows :: proc(cmd: string) -> (output: string, success: bool) {
	c_cmd := strings.clone_to_cstring(cmd)
	defer delete(c_cmd)

	pipe := _popen(c_cmd, "r")
	if pipe == nil { return "", false }

	builder := strings.builder_make()
	buffer: [256]u8
	for feof(pipe) == 0 {
		if fgets(&buffer[0], 256, pipe) != nil {
			strings.write_string(&builder, string(cstring(&buffer[0])))
		}
	}
	exit_code := _pclose(pipe)
	out := strings.to_string(builder)
	return _finalize_command_result(cmd, out, exit_code)
}

execute_command_unix :: proc(cmd: string) -> (output: string, success: bool) {
	c_cmd := strings.clone_to_cstring(cmd)
	defer delete(c_cmd)

	pipe := popen(c_cmd, "r")
	if pipe == nil { return "", false }

	builder := strings.builder_make()
	buffer: [256]u8
	for feof(pipe) == 0 {
		if fgets(&buffer[0], 256, pipe) != nil {
			strings.write_string(&builder, string(cstring(&buffer[0])))
		}
	}
	exit_code := pclose(pipe)
	out := strings.to_string(builder)
	return _finalize_command_result(cmd, out, exit_code)
}
