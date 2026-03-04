package suite

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"

run_incremental_suite :: proc(root_dir: string, config_file: string, include_patterns: [dynamic]string, exclude_patterns: [dynamic]string, plan: SuitePlan, debug_build: bool, force_build: bool, run_after: bool, run_args: [dynamic]string) {
	exe_path       := os.args[0]
	exe_dir        := filepath.dir(exe_path)
	clean_root_dir := filepath.clean(root_dir)
	defer delete(clean_root_dir)
	log_path    := filepath.join({exe_dir, LOG_FILE_NAME})
	stamps_path := filepath.join({exe_dir, STAMPS_FILE_NAME})

	os.write_entire_file(log_path, []u8{})

	stamps := load_stamps(stamps_path)
	b      := strings.builder_make()

	// ── Load config ────────────────────────────────────────────────────────────
	all_entries, collections, config_ok := load_suite_config(clean_root_dir, config_file)
	if !config_ok {
		config_display := config_file if len(config_file) > 0 else SUITE_CONFIG
		fmt.eprintf("%serror:%s could not read %s in %s\n", RED, RESET, config_display, clean_root_dir)
		fmt.sbprintf(&b, "fail: could not read %s in %s\n", config_display, clean_root_dir)
		log := strings.clone(strings.to_string(b))
		os.write_entire_file(log_path, transmute([]u8)log)
		delete(log)
		suite_exit(1)
	}
	defer {
		for e in all_entries { delete(e.path); delete(e.name) }
		delete(all_entries)
		for c in collections { delete(c.name); delete(c.path) }
		delete(collections)
	}

	has_includes := len(include_patterns) > 0

	// ── Filter entries ─────────────────────────────────────────────────────────
	filtered := make([dynamic]SuiteEntry)
	defer delete(filtered)
	for entry in all_entries {
		if has_includes && !matches_any_pattern(entry.name, include_patterns[:]) &&
		   !matches_any_pattern(entry.path, include_patterns[:]) { continue }
		if matches_any_pattern(filepath.base(entry.path), exclude_patterns[:]) { continue }
		append(&filtered, entry)
	}

	if len(filtered) == 0 {
		if has_includes {
			fmt.eprintf("%serror:%s no entries matched include filter\n", RED, RESET)
			fmt.sbprintf(&b, "fail: no entries matched include filter\n")
			log := strings.clone(strings.to_string(b))
			os.write_entire_file(log_path, transmute([]u8)log)
			delete(log)
		} else if len(exclude_patterns) > 0 {
			fmt.eprintln("No packages found, skipping suite.")
			suite_exit(0)
		} else {
			fmt.eprintf("%serror:%s .zs has no entries\n", RED, RESET)
			fmt.sbprintf(&b, "fail: .zs has no entries\n")
			log := strings.clone(strings.to_string(b))
			os.write_entire_file(log_path, transmute([]u8)log)
			delete(log)
		}
		suite_exit(1)
	}

	failed_any := false

	// ── Run all entries (with table display) ───────────────────────────────────
	if len(filtered) > 0 {
		main_failed := run_main_entries(clean_root_dir, filtered[:], collections[:], &stamps, plan, debug_build, force_build, &b)
		if main_failed { failed_any = true }
	}

	save_stamps(stamps, stamps_path)

	if failed_any {
		fmt.sbprintf(&b, "suite: completed with failures\n")
	} else {
		fmt.sbprintf(&b, "suite: completed successfully\n")
	}

	log := strings.clone(strings.to_string(b))
	os.write_entire_file(log_path, transmute([]u8)log)
	delete(log)

	if failed_any { suite_exit(1) }

	// ── Run main executable if requested ───────────────────────────────────────
	if run_after {
		// Find the main entry.
		main_entry: Maybe(SuiteEntry)
		for entry in all_entries {
			if entry.is_main {
				main_entry = entry
				break
			}
		}
		if main_entry == nil {
			fmt.eprintf("%serror:%s no main entry defined (use 'main: path' in config)\n", RED, RESET)
			suite_exit(1)
		}
		entry := main_entry.?

		// Build the executable path.
		when ODIN_OS == .Windows { exe_ext :: ".exe" } else { exe_ext :: "" }
		main_exe := filepath.join({clean_root_dir, filepath.dir(entry.path), "bin",
			strings.concatenate({entry.name, exe_ext})})
		defer delete(main_exe)

		if !os.exists(main_exe) {
			fmt.eprintf("%serror:%s main executable not found: %s\n", RED, RESET, main_exe)
			suite_exit(1)
		}

		fmt.printf("\n%s── running %s ──%s\n\n", BLUE, entry.name, RESET)

		// Build command with optional arguments.
		cmd: string
		if len(run_args) > 0 {
			b := strings.builder_make()
			strings.write_string(&b, main_exe)
			for arg in run_args {
				strings.write_string(&b, " ")
				// Quote args containing spaces.
				if strings.contains(arg, " ") {
					strings.write_string(&b, "\"")
					strings.write_string(&b, arg)
					strings.write_string(&b, "\"")
				} else {
					strings.write_string(&b, arg)
				}
			}
			cmd = strings.to_string(b)
		} else {
			cmd = main_exe
		}
		defer if len(run_args) > 0 { delete(cmd) }

		// Execute the main program with TTY access for interactive programs.
		success := execute_command_interactive(cmd)
		if !success { suite_exit(1) }
	}

	suite_exit(0)
}

// ── run_main_entries: Run main entries with table display ──────────────────────

run_main_entries :: proc(
	root_dir:    string,
	entries:     []SuiteEntry,
	collections: []CollectionDecl,
	stamps:      ^map[string]string,
	plan:        SuitePlan,
	debug_build: bool,
	force_build: bool,
	log_builder: ^strings.Builder,
) -> (failed: bool) {
	if len(entries) == 0 { return false }

	stale_indices      := make([dynamic]int)
	stale_table_starts := make([dynamic]int)
	stale_hashes       := make([dynamic]string)
	defer delete(stale_indices)
	defer delete(stale_table_starts)
	defer delete(stale_hashes)

	table_rows := make([dynamic]TableRow)

	for i in 0..<len(entries) {
		entry := entries[i]

		// Check if entry directory exists.
		entry_dir := filepath.join({root_dir, entry.path})
		dir_exists := os.exists(entry_dir)
		delete(entry_dir)

		if !dir_exists {
			fmt.sbprintf(log_builder, "error %s: directory does not exist\n", entry.path)
			row := TableRow{suite = strings.clone(entry.name)}
			row.check_state = .Failed if plan_has_step(plan, .Check) else .Skipped
			row.check_info  = "missing"
			row.test_state  = .Skipped
			row.build_state = .Skipped
			row.errors      = strings.clone(fmt.tprintf("directory '%s' not found", entry.path))
			append(&table_rows, row)
			failed = true
			continue
		}

		// Compute hash including entry source + all collections.
		current_hash := hash_with_collections(root_dir, entry.path, collections)

		// Check if stamp matches.
		stored_hash := stamps^[entry.path] if entry.path in stamps^ else ""
		is_cached := !force_build && len(stored_hash) > 0 && stored_hash == current_hash

		// For build entries, also verify artifact exists.
		if is_cached && plan_has_step(plan, .Build) && (entry.kind == .Build || entry.kind == .Shared) {
			when ODIN_OS == .Windows { artifact_ext :: ".exe" } else { artifact_ext :: "" }
			artifact_path: string
			if entry.kind == .Shared {
				artifact_path = filepath.join({root_dir, entry.path, "bin",
					strings.concatenate({entry.name, suite_lib_ext()})})
			} else {
				artifact_path = filepath.join({root_dir, filepath.dir(entry.path), "bin",
					strings.concatenate({entry.name, artifact_ext})})
			}
			if !os.exists(artifact_path) {
				is_cached = false
				fmt.sbprintf(log_builder, "stale %s: artifact missing\n", entry.name)
			}
			delete(artifact_path)
		}

		if is_cached {
			row := TableRow{suite = strings.clone(entry.name)}
			row.check_state = .Passed if plan_has_step(plan, .Check) else .Skipped
			row.check_info  = "cached" if plan_has_step(plan, .Check) else ""
			row.test_state  = .Passed if plan_has_step(plan, .Test)  else .Skipped
			row.test_info   = "cached" if plan_has_step(plan, .Test)  else ""
			row.build_state = .Passed if plan_has_step(plan, .Build) else .Skipped
			row.build_info  = "cached" if plan_has_step(plan, .Build) else ""
			append(&table_rows, row)
			delete(current_hash)
			continue
		}

		append(&stale_indices, i)
		append(&stale_table_starts, len(table_rows))
		append(&stale_hashes, current_hash)
		{
			row := TableRow{suite = strings.clone(entry.name)}
			row.check_state = .Pending if plan_has_step(plan, .Check) else .Skipped
			row.test_state  = .Pending if plan_has_step(plan, .Test)  else .Skipped
			row.build_state = .Pending if plan_has_step(plan, .Build) else .Skipped
			append(&table_rows, row)
		}
	}

	if len(stale_indices) > 0 {
		stale_entries := make([]SuiteEntry, len(stale_indices))
		defer delete(stale_entries)
		for j in 0..<len(stale_indices) {
			stale_entries[j] = entries[stale_indices[j]]
		}

		worker_datas := make([]EntryWorkerData, len(stale_indices))
		results      := make([]EntryResult, len(stale_indices))
		done_flags   := make([]bool, len(stale_indices))
		threads      := make([dynamic]^thread.Thread)
		defer {
			delete(threads)
			delete(worker_datas)
			delete(done_flags)
		}

		for j in 0..<len(stale_indices) {
			worker_datas[j] = EntryWorkerData{
				idx              = j,
				entries          = stale_entries,
				results          = &results,
				root_dir         = root_dir,
				collections      = collections,
				plan             = plan,
				debug_build      = debug_build,
				current_hash     = stale_hashes[j],
				table_rows       = &table_rows,
				table_rows_start = stale_table_starts[j],
				done_flag        = &done_flags[j],
			}

			t := thread.create(run_entry_worker)
			t.data = &worker_datas[j]
			thread.start(t)
			append(&threads, t)
		}

		// Live update loop.
		live_height := 0
		prev_snap   := make([]TableRow, len(table_rows))
		defer delete(prev_snap)

		fmt.printf("\x1b[?25l") // hide cursor
		for {
			all_done := true
			for j in 0..<len(stale_indices) {
				if !done_flags[j] { all_done = false; break }
			}
			prev := prev_snap[:] if live_height > 0 else nil
			live_height = print_table(table_rows[:], prev, true)
			copy(prev_snap, table_rows[:])
			if all_done { break }
			time.sleep(50 * time.Millisecond)
		}
		fmt.printf("\x1b[?25h") // restore cursor
		if live_height > 0 { fmt.printf("\x1b[%dA\x1b[0J", live_height) }

		for t in threads { thread.join(t); thread.destroy(t) }

		for j in 0..<len(stale_indices) {
			result := results[j]
			if result.status == .Failed { failed = true }
			if result.update_stamp {
				stamps^[strings.clone(result.stamp_key)] = strings.clone(result.stamp_hash)
			}
			delete(result.stamp_key)
			delete(result.stamp_hash)
			fmt.sbprintf(log_builder, "%s", result.log_output)
			delete(result.log_output)
		}
		delete(results)
	}

	print_table(table_rows[:], nil)
	delete(table_rows)

	return failed
}
