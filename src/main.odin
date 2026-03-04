package suite

import "core:fmt"
import "core:os"

main :: proc() {
	plan, include_patterns, exclude_patterns, root_dir, config_file, debug_build, force_build, run_after, show_help, error_msg, ok := parse_cli_args(os.args[1:])
	if show_help {
		suite_usage()
		return
	}
	if !ok {
		fmt.eprintf("%serror:%s %s\n", RED, RESET, error_msg)
		fmt.eprintln("use -help for usage")
		suite_exit(1)
	}
	run_incremental_suite(root_dir, config_file, include_patterns, exclude_patterns, plan, debug_build, force_build, run_after)
}
