SHELL := /bin/bash
.PHONY: check test test-migration test-system test-full release-check test-linux-files test-fuzz
check:
	python3 tests/quality.py
test:
	python3 -B tests/run.py
	python3 tests/go_tests.py codex-hud
	python3 tests/go_tests.py ssh
test-linux-files:
	python3 tests/container.py
test-fuzz:
	python3 tests/go_tests.py ssh --fuzz FuzzInventory
	python3 tests/go_tests.py ssh --fuzz FuzzLegacyMetadata
test-migration:
	python3 tests/go_tests.py ssh --run 'Migration|Transaction|Rollback|Legacy|CLI'
	python3 tests/go_tests.py codex-hud --run 'Install|Setup|Uninstall|Format'
test-system:
	python3 tests/system/vm.py --image ubuntu --suite docker --package-lock tests/system/apt/ubuntu.lock.json
test-full: check test test-migration test-system test-linux-files test-fuzz
	python3 tests/system/vm.py --image debian --suite docker --package-lock tests/system/apt/debian.lock.json
	python3 tests/system/vm.py --image openwrt --suite core --package-lock tests/system/opkg/openwrt.lock.json
release-check: test-full
	python3 scripts/release_check.py
