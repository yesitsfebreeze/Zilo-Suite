default: build

set shell := ["bash", "-c"]
set windows-shell := ["powershell", "-NoProfile", "-Command"]

ext := if os() == "windows" { ".exe" } else { "" }

build:
	odin build src -out:zilo_suite{{ext}} -o:speed

debug:
	odin build src -out:zilo_suite{{ext}} -debug

clean:
	rm -f suite{{ext}}

install: build
	cp zilo_suite{{ext}} ~/.local/bin/zs{{ext}}
