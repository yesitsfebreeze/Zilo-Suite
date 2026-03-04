package suite

import "core:fmt"
import "core:hash"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

@(private)
_is_safe_collection_name :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	for ch in s {
		if (ch >= 'a' && ch <= 'z') ||
		   (ch >= 'A' && ch <= 'Z') ||
		   (ch >= '0' && ch <= '9') ||
		   ch == '_' || ch == '-' {
			continue
		}
		return false
	}
	return true
}

@(private)
_is_safe_suite_path :: proc(s: string) -> bool {
	if len(s) == 0 { return false }
	if strings.has_prefix(s, "/") || strings.has_prefix(s, "\\") { return false }
	if len(s) >= 2 && s[1] == ':' { return false }
	if strings.contains(s, "..") { return false }
	for ch in s {
		if (ch >= 'a' && ch <= 'z') ||
		   (ch >= 'A' && ch <= 'Z') ||
		   (ch >= '0' && ch <= '9') {
			continue
		}
		switch ch {
		case '/', '\\', '_', '-', '.', '@':
		case:
			return false
		}
	}
	return true
}

// load_suite_config reads the .zs file from root_dir.
// Format per line:
//   build_args: collection name=relative/path
//   entry: relative/path
//   # comment or blank line
//
// Each entry runs check → test → build as controlled by CLI flags.
load_suite_config :: proc(root_dir: string, config_file: string = "") -> (entries: [dynamic]SuiteEntry, collections: [dynamic]CollectionDecl, ok: bool) {
	entries     = make([dynamic]SuiteEntry)
	collections = make([dynamic]CollectionDecl)

	config_path := filepath.join({root_dir, config_file}) if len(config_file) > 0 else filepath.join({root_dir, SUITE_CONFIG})
	defer delete(config_path)

	data, read_ok := os.read_entire_file(config_path)
	if !read_ok {
		return entries, collections, false
	}
	defer delete(data)

	lines := strings.split_lines(string(data))
	defer delete(lines)

	for line in lines {
		t := strings.trim_space(line)
		if len(t) == 0 || strings.has_prefix(t, "#") { continue }

		// build_args: collection name=path
		if strings.has_prefix(t, "build_args:") {
			rest := strings.trim_space(t[len("build_args:"):])
			if strings.has_prefix(rest, "collection ") {
				decl := strings.trim_space(rest[len("collection "):])
				eq := strings.index(decl, "=")
				if eq < 0 { continue }
				col_name := strings.trim_space(decl[:eq])
				col_path := strings.trim_space(decl[eq + 1:])
				if len(col_name) == 0 || len(col_path) == 0 { continue }
				if !_is_safe_collection_name(col_name) || !_is_safe_suite_path(col_path) { continue }
				append(&collections, CollectionDecl{
					name = strings.clone(col_name),
					path = strings.clone(col_path),
				})
			}
			continue
		}

		// entry: path [nostrict]
		if strings.has_prefix(t, "entry:") {
			rest := strings.trim_space(t[len("entry:"):])
			if len(rest) == 0 { continue }
			ns := strings.has_suffix(rest, "nostrict")
			path := strings.trim_space(rest[:len(rest) - len("nostrict")]) if ns else rest
			if len(path) == 0 { continue }
			if !_is_safe_suite_path(path) { continue }
			name := filepath.base(path)
			append(&entries, SuiteEntry{
				kind     = .Build,
				path     = strings.clone(path),
				name     = strings.clone(name),
				nostrict = ns,
			})
			continue
		}

		// main: path [nostrict]  (same as entry but marks this as the main executable)
		if strings.has_prefix(t, "main:") {
			rest := strings.trim_space(t[len("main:"):])
			if len(rest) == 0 { continue }
			ns := strings.has_suffix(rest, "nostrict")
			path := strings.trim_space(rest[:len(rest) - len("nostrict")]) if ns else rest
			if len(path) == 0 { continue }
			if !_is_safe_suite_path(path) { continue }
			name := filepath.base(path)
			append(&entries, SuiteEntry{
				kind     = .Build,
				path     = strings.clone(path),
				name     = strings.clone(name),
				nostrict = ns,
				is_main  = true,
			})
			continue
		}

		// test: path [nostrict]  (check + test only, no build)
		if strings.has_prefix(t, "test:") {
			rest := strings.trim_space(t[len("test:"):])
			if len(rest) == 0 { continue }
			ns := strings.has_suffix(rest, "nostrict")
			path := strings.trim_space(rest[:len(rest) - len("nostrict")]) if ns else rest
			if len(path) == 0 { continue }
			if !_is_safe_suite_path(path) { continue }
			name := filepath.base(path)
			append(&entries, SuiteEntry{
				kind     = .Test,
				path     = strings.clone(path),
				name     = strings.clone(name),
				nostrict = ns,
			})
			continue
		}

		// shared: path [nostrict]  (check + build as shared library)
		if strings.has_prefix(t, "shared:") {
			rest := strings.trim_space(t[len("shared:"):])
			if len(rest) == 0 { continue }
			ns := strings.has_suffix(rest, "nostrict")
			path := strings.trim_space(rest[:len(rest) - len("nostrict")]) if ns else rest
			if len(path) == 0 { continue }
			if !_is_safe_suite_path(path) { continue }
			name := filepath.base(path)
			append(&entries, SuiteEntry{
				kind     = .Shared,
				path     = strings.clone(path),
				name     = strings.clone(name),
				nostrict = ns,
			})
			continue
		}

		// check: path [nostrict]  (check only, no test, no build)
		if strings.has_prefix(t, "check:") {
			rest := strings.trim_space(t[len("check:"):])
			if len(rest) == 0 { continue }
			ns := strings.has_suffix(rest, "nostrict")
			path := strings.trim_space(rest[:len(rest) - len("nostrict")]) if ns else rest
			if len(path) == 0 { continue }
			if !_is_safe_suite_path(path) { continue }
			name := filepath.base(path)
			append(&entries, SuiteEntry{
				kind     = .Check,
				path     = strings.clone(path),
				name     = strings.clone(name),
				nostrict = ns,
			})
			continue
		}
	}

	return entries, collections, true
}

// hash_source_dir returns a hex string of the FNV-64a hash of all .odin
// file contents under target, keyed by sorted relative paths.
// Returns "" if the directory cannot be read.
hash_source_dir :: proc(target: string) -> string {
	paths := make([dynamic]string)
	defer {
		for p in paths { delete(p) }
		delete(paths)
	}
	_collect_odin_paths(target, target, &paths)
	if len(paths) == 0 { return "" }
	slice.sort(paths[:])

	// Accumulate path+NUL+content+NUL for all files, then hash.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	for abs_path in paths {
		// Use path relative to target as the hash key to stay machine-independent.
		rel := abs_path[len(target):]
		strings.write_string(&b, rel)
		strings.write_byte(&b, 0)
		data, rok := os.read_entire_file(abs_path)
		if rok {
			strings.write_bytes(&b, data)
			delete(data)
		}
		strings.write_byte(&b, 0)
	}
	h := hash.fnv64a(transmute([]byte)strings.to_string(b))
	return fmt.aprintf("%016x", h)
}

// hash_with_collections computes a combined hash of the entry's source directory
// and all collection directories. This ensures that if any dependency (collection)
// changes, the entry is considered stale.
hash_with_collections :: proc(root_dir: string, entry_path: string, collections: []CollectionDecl) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// Hash the entry's own source.
	joined_target := filepath.join({root_dir, entry_path})
	abs_target, abs_ok := filepath.abs(joined_target)
	if !abs_ok { abs_target = joined_target } else { delete(joined_target) }
	entry_hash := hash_source_dir(abs_target)
	delete(abs_target)
	strings.write_string(&b, entry_hash)
	strings.write_byte(&b, 0)
	delete(entry_hash)

	// Hash each collection (sorted by name for determinism).
	col_names := make([dynamic]string, 0, len(collections))
	defer delete(col_names)
	for c in collections { append(&col_names, c.name) }
	slice.sort(col_names[:])

	for col_name in col_names {
		for c in collections {
			if c.name == col_name {
				col_abs := filepath.join({root_dir, c.path})
				col_hash := hash_source_dir(col_abs)
				delete(col_abs)
				strings.write_string(&b, col_name)
				strings.write_byte(&b, ':')
				strings.write_string(&b, col_hash)
				strings.write_byte(&b, 0)
				delete(col_hash)
				break
			}
		}
	}

	h := hash.fnv64a(transmute([]byte)strings.to_string(b))
	return fmt.aprintf("%016x", h)
}

@(private)
_collect_odin_paths :: proc(root: string, dir: string, out: ^[dynamic]string) {
	fh, err := os.open(dir)
	if err != nil { return }
	defer os.close(fh)

	infos, read_err := os.read_dir(fh, 0)
	if read_err != nil { return }
	defer os.file_info_slice_delete(infos)

	for info in infos {
		if info.is_dir {
			sub := filepath.join({dir, info.name})
			_collect_odin_paths(root, sub, out)
			delete(sub)
		} else if strings.has_suffix(info.name, ".odin") {
			joined := filepath.join({dir, info.name})
			append(out, joined)
		}
	}
}
