SHELL := /bin/bash

.PHONY: version build-version build-app dmg bump-patch bump-minor bump-major release release-minor release-major release-dry-run cleanup-releases cleanup-releases-dry-run

version:
	./scripts/read_version.sh

build-version:
	./scripts/read_build_version.sh

build-app:
	./scripts/build_app.sh

dmg:
	./scripts/create_dmg.sh

bump-patch:
	./scripts/bump_version.sh patch

bump-minor:
	./scripts/bump_version.sh minor

bump-major:
	./scripts/bump_version.sh major

release:
	./scripts/release.sh --patch

release-minor:
	./scripts/release.sh --minor

release-major:
	./scripts/release.sh --major

release-dry-run:
	./scripts/release.sh --dry-run

cleanup-releases:
	./scripts/cleanup_releases.sh

cleanup-releases-dry-run:
	./scripts/cleanup_releases.sh --dry-run
