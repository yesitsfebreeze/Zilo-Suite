default: build

set shell := ["bash", "-c"]
set windows-shell := ["powershell", "-NoProfile", "-Command"]

ext := if os() == "windows" { ".exe" } else { "" }

build:
	odin build src -out:zs{{ext}} -o:speed

debug:
	odin build src -out:zs{{ext}} -debug

clean:
	rm -f suite{{ext}}

install: build
	cp zs{{ext}} ~/.local/bin/zs{{ext}}
