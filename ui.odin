package suite

import "core:fmt"
import "core:os"
import "core:strings"

suite_exit :: proc(code: int) {
	os.exit(code)
}

// ─── Unified table ────────────────────────────────────────────────────────────
//
// One row per entry:   SUITE | CHECK | TEST      | BUILD
//
// redraw=false (final mode):
//   Uses fmt.printf, prints ERRORS section below.
//
// redraw=true (live mode):
//   Atomically rewrites the table in place each tick.
//   Returns the number of lines printed for cursor management.

@(private="file")
step_abbrev :: proc(state: TaskState) -> string {
	switch state {
	case .Passed:  return "OK  "
	case .Failed:  return "FAIL"
	case .Running: return "RUN "
	case .Skipped: return "----"
	case .Pending: return "PEND"
	}
	return "?   "
}

@(private="file")
step_color :: proc(state: TaskState) -> string {
	switch state {
	case .Passed:  return GREEN
	case .Failed:  return RED
	case .Running: return YELLOW
	case .Skipped: return DIM
	case .Pending: return DIM
	}
	return DIM
}

// step_cell_len returns the display width of a step cell.
@(private="file")
step_cell_len :: proc(state: TaskState, info: string) -> int {
	n := len(step_abbrev(state))
	if len(info) > 0 { n += 1 + len(info) }
	return n
}

// write_step_cell writes the colored state+info into b, padded to col_w.
@(private="file")
write_step_cell :: proc(b: ^strings.Builder, state: TaskState, info: string, col_w: int, erase := false) {
	abbrev := step_abbrev(state)
	color  := step_color(state)
	fmt.sbprintf(b, "%s%s%s", color, abbrev, RESET)
	if len(info) > 0 { fmt.sbprintf(b, " %s", info) }
	pad := col_w - step_cell_len(state, info)
	for _ in 0..<pad { strings.write_byte(b, ' ') }
	if erase { strings.write_string(b, "\x1b[K") }
}

print_table :: proc(rows: []TableRow, prev: []TableRow, redraw := false) -> (lines_printed: int) {
	if len(rows) == 0 { return 0 }

	// ── Compute column widths ─────────────────────────────────────────────────
	suite_w := len("SUITE")
	for r in rows { if len(r.suite) > suite_w { suite_w = len(r.suite) } }
	suite_w += 1

	chk_w := len("CHECK")
	tst_w := len("TEST")
	bld_w := len("BUILD")
	for r in rows {
		if w := step_cell_len(r.check_state, r.check_info); w > chk_w { chk_w = w }
		if w := step_cell_len(r.test_state,  r.test_info);  w > tst_w { tst_w = w }
		if w := step_cell_len(r.build_state, r.build_info); w > bld_w { bld_w = w }
	}

	sep := strings.repeat("-", suite_w + 3 + chk_w + 3 + tst_w + 3 + bld_w)
	defer delete(sep)

	if redraw {
		// ── Live mode ─────────────────────────────────────────────────────
		lines_printed = 2 + len(rows)

		b := strings.builder_make()
		defer strings.builder_destroy(&b)

		if prev != nil { fmt.sbprintf(&b, "\x1b[%dA\r", lines_printed) }

		fmt.sbprintf(&b, "%s%-*s%s | %-*s | %-*s | %-*s\x1b[K\n",
			BOLD, suite_w, "SUITE", RESET,
			chk_w, "CHECK",
			tst_w, "TEST",
			bld_w, "BUILD",
		)
		fmt.sbprintf(&b, "%s\x1b[K\n", sep)

		for i in 0..<len(rows) {
			r := rows[i]
			if prev != nil && i < len(prev) {
				p := prev[i]
				if p.check_state == r.check_state && p.check_info == r.check_info &&
				   p.test_state  == r.test_state  && p.test_info  == r.test_info  &&
				   p.build_state == r.build_state && p.build_info == r.build_info {
					fmt.sbprintf(&b, "\x1b[1B\r")
					continue
				}
			}
			fmt.sbprintf(&b, "%s%-*s%s | ", BLUE, suite_w, r.suite, RESET)
			write_step_cell(&b, r.check_state, r.check_info, chk_w)
			strings.write_string(&b, " | ")
			write_step_cell(&b, r.test_state, r.test_info, tst_w)
			strings.write_string(&b, " | ")
			write_step_cell(&b, r.build_state, r.build_info, bld_w, true)
			strings.write_byte(&b, '\n')
		}

		os.write(os.stdout, transmute([]u8)strings.to_string(b))

	} else {
		// ── Final mode ────────────────────────────────────────────────────
		fmt.printf("%s%-*s%s | %-*s | %-*s | %-*s\n",
			BOLD, suite_w, "SUITE", RESET,
			chk_w, "CHECK",
			tst_w, "TEST",
			bld_w, "BUILD",
		)
		fmt.printf("%s\n", sep)

		for r in rows {
			b := strings.builder_make()
			fmt.sbprintf(&b, "%s%-*s%s | ", BLUE, suite_w, r.suite, RESET)
			write_step_cell(&b, r.check_state, r.check_info, chk_w)
			strings.write_string(&b, " | ")
			write_step_cell(&b, r.test_state, r.test_info, tst_w)
			strings.write_string(&b, " | ")
			write_step_cell(&b, r.build_state, r.build_info, bld_w)
			strings.write_byte(&b, '\n')
			fmt.print(strings.to_string(b))
			strings.builder_destroy(&b)
		}

		// ── ERRORS section ────────────────────────────────────────────────
		has_errors := false
		for r in rows { if len(r.errors) > 0 { has_errors = true; break } }
		if !has_errors {
			fmt.printf("\n")
			return
		}

		fmt.printf("\n\n\nERRORS\n\n")

		long_sep := strings.repeat("-", 79)
		defer delete(long_sep)

		first := true
		for r in rows {
			if len(r.errors) == 0 { continue }

			// Determine which step failed for the task label.
			task_str := "check"
			if      r.check_state == .Failed { task_str = "check" }
			else if r.test_state  == .Failed { task_str = "test " }
			else if r.build_state == .Failed { task_str = "build" }

			if !first { fmt.printf("%s\n", long_sep) }
			first = false

			raw    := strings.trim_space(r.errors)
			blocks := strings.split(raw, "\n\n")

			err_num := 1
			for block in blocks {
				trimmed := strings.trim_space(block)
				if len(trimmed) == 0 { continue }
				lines := strings.split_lines(trimmed)

				num_len := len(fmt.tprintf("%d", err_num))
				pad_len := suite_w + 3 + len(task_str) + 3 + num_len + 3
				padding := strings.repeat(" ", pad_len)

				for line, li in lines {
					clean := strings.trim_right(line, " \t\r")
					if len(clean) == 0 { continue }
					if li == 0 {
						fmt.printf("%s%-*s%s | %s | %d | %s\n",
							BLUE, suite_w, r.suite, RESET,
							task_str, err_num, clean,
						)
					} else {
						fmt.printf("%s| %s\n", padding, clean)
					}
				}
				delete(padding)
				delete(lines)
				fmt.printf("\n")
				err_num += 1
			}
			delete(blocks)
		}
	}
	return
}
