package suite

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

load_stamps :: proc(path: string) -> map[string]string {
	m := make(map[string]string)
	data, read_ok := os.read_entire_file(path)
	if !read_ok { return m }
	defer delete(data)
	lines := strings.split_lines(string(data))
	defer delete(lines)
	for line in lines {
		trim := strings.trim_space(line)
		if len(trim) == 0 { continue }
		idx := strings.index(trim, "|")
		if idx <= 0 { continue }
		k := strings.clone(trim[:idx])
		v := strings.clone(strings.trim_space(trim[idx+1:]))
		m[k] = v
	}
	return m
}

save_stamps :: proc(stamps: map[string]string, path: string) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	keys := make([dynamic]string, 0, len(stamps))
	defer delete(keys)
	for k in stamps { append(&keys, k) }
	slice.sort(keys[:])
	for k in keys {
		fmt.sbprintf(&b, "%s|%s\n", k, stamps[k])
	}
	os.write_entire_file(path, transmute([]u8)strings.to_string(b))
}
