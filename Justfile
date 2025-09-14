# ----------------------------------------
# Justfile for Justfile LSP (Nim)
# ----------------------------------------

# Use bash
set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

# Binary name and dirs
bin      := "justls"
bindir   := "bin"
entry_point := "src/main.nim"

# Nim flags
nim_release_flags := "--mm:orc --opt:speed --passC:-O3 -d:release"
nim_debug_flags   := "-d:debug --errorMax:500"

# Default target
default: build

# Release build (native)
build: setup ensure-bindir
	@echo "==> Building release (native)"
	nim c {{nim_release_flags}} --out:{{bindir}}/{{bin}} {{entry_point}}

# Debug build (native)
build-debug: setup ensure-bindir
	@echo "==> Building debug (native)"
	nim c {{nim_debug_flags}} --out:{{bindir}}/{{bin}}-debug {{entry_point}}

# Install deps from nimble
setup:
	nimble install --depsOnly -y

# Format nim sources (requires nimpretty)
format:
	find . -name '*.nim' -not -path './nimcache/*' -exec nimpretty {} +

# Type-check without building (fast)
check:
	nimble check || true

# Remove build artifacts
clean:
	rm -rf nimcache {{bindir}} ./{{bin}} ./{{bin}}-debug || true

# Print where the binary ended up
where:
	@echo "==> Built binaries:"
	@ls -lh {{bindir}}/{{bin}}* 2>/dev/null || echo "(none)"

# Ensure bin dir exists
ensure-bindir:
	mkdir -p {{bindir}}

# Simple help
help:
	@echo "Targets:"
	@echo "  build / build-debug            - native builds"
	@echo "  setup                          - install nimble deps"
	@echo "  format                         - nimpretty all .nim"
	@echo "  check                          - nimble check"
	@echo "  clean                          - remove artifacts"
	@echo "  where                          - list built binaries"
