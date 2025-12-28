#!/usr/bin/env bats

# Bats is a testing framework for Bash
# Documentation https://bats-core.readthedocs.io/en/stable/
# Bats libraries documentation https://github.com/ztombol/bats-docs

# For local tests, install bats-core, bats-assert, bats-file, bats-support
# And run this in the add-on root directory:
#   bats ./tests/test.bats
# To exclude release tests:
#   bats ./tests/test.bats --filter-tags '!release'
# To run the full Drupal install test:
#   DCQ_FULL_TESTS=1 bats ./tests/test.bats --filter-tags 'full'
# For debugging:
#   bats ./tests/test.bats --show-output-of-passing-tests --verbose-run --print-output-on-failure

setup() {
  set -eu -o pipefail

  # Override this variable for your add-on:
  export GITHUB_REPO=UltraBob/ddev-drupal-code-quality

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p "${HOME}/tmp"
  export TESTDIR="$(mktemp -d "${HOME}/tmp/${PROJNAME}.XXXXXX")"
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
  run ddev config --project-name="${PROJNAME}" --project-tld=ddev.site --project-type=drupal11 --docroot=web
  assert_success
  run ddev start -y
  assert_success
}

health_checks() {
  # Do something useful here that verifies the add-on

  # You can check for specific information in headers:
  # run curl -sfI https://${PROJNAME}.ddev.site
  # assert_output --partial "HTTP/2 200"
  # assert_output --partial "test_header"

  # Or check if some command gives expected output:
  DDEV_DEBUG=true run ddev launch
  assert_success
  assert_output --partial "FULLURL https://${PROJNAME}.ddev.site"
}

assert_addon_installed() {
  assert_file_exist ".ddev/commands/web/phpstan"
  assert_file_exist "dcq-tooling/bin/phpstan"
  assert_file_exist "tooling/ci-config/phpstan.neon"
  assert_file_exist ".eslintrc.json"
  assert_file_exist ".phpcs.xml"
}

teardown() {
  set -eu -o pipefail
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1
  # Persist TESTDIR if running inside GitHub Actions. Useful for uploading test result artifacts
  # See example at https://github.com/ddev/github-action-add-on-test#preserving-artifacts
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

@test "install from directory" {
  set -eu -o pipefail
  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  assert_addon_installed
  health_checks
}

# bats test_tags=release
@test "install from release" {
  set -eu -o pipefail
  echo "# ddev add-on get ${GITHUB_REPO} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${GITHUB_REPO}"
  assert_success
  run ddev restart -y
  assert_success
  assert_addon_installed
  health_checks
}

# bats test_tags=full
@test "fresh install (full)" {
  set -eu -o pipefail
  if [ "${DCQ_FULL_TESTS:-}" != "1" ]; then
    skip "Set DCQ_FULL_TESTS=1 to run the full Drupal install test."
  fi

  run ddev composer create-project "drupal/recommended-project:^11" .
  assert_success
  run ddev composer require drush/drush
  assert_success
  run ddev drush site:install --account-name=admin --account-pass=admin -y
  assert_success

  export DCQ_INSTALL_DEPS=install
  export DCQ_INSTALL_NODE_DEPS=skip
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success
  assert_addon_installed

  run ./dcq-tooling/bin/phpstan --version
  assert_success
  run ./dcq-tooling/bin/phpcs --version
  assert_success
  run ./dcq-tooling/bin/phpcbf --version
  assert_success
}
