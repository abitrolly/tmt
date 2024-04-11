#!/bin/bash

. /usr/share/beakerlib/beakerlib.sh || exit 1

rlJournalStart
    rlPhaseStartSetup
        # TODO: `test` seems more natural, but creates 3 environments,
        # one per available Python installation. I need to check whether
        # to disable or take advantage of it.
        HATCH_ENVIRONMENT="${HATCH_ENVIRONMENT:-dev}"

        rlLogInfo "WITH_SYSTEM_PACKAGES=$WITH_SYSTEM_PACKAGES"
        rlLogInfo "HATCH_ENVIRONMENT=$HATCH_ENVIRONMENT"

        rlLogInfo "pip is $(which pip), $(pip --version)"
        rlLogInfo "hatch is $(which hatch), $(hatch --version)"
    rlPhaseEnd

    if [ "$WITH_SYSTEM_PACKAGES" = "yes" ]; then
        rlPhaseStartTest "Check type annotations against system Python packages"
            rlRun "mypy_version=$(yq -r '.repos | .[] | select(.repo | test("^.*/mirrors-mypy$")) | .rev' ../../.pre-commit-config.yaml | tr -d 'v')"
            rlRun "pyright_version=$(yq -r '.repos | .[] | select(.repo | test("^.*/pyright-python$")) | .rev' ../../.pre-commit-config.yaml | tr -d 'v')"

            rlRun "TEST_VENV=$(mktemp -d)"

            rlRun "python3 -m venv $TEST_VENV --system-site-packages"
            rlRun "$TEST_VENV/bin/pip install mypy==$mypy_version pyright==$pyright_version"

            # Note: we're not in the root directory!
            pushd ../../
            rlRun "$TEST_VENV/bin/python3 -m mypy --config-file=pyproject.toml --install-types"
            rlRun "$TEST_VENV/bin/python3 -m pyright"
            popd

            rlRun "rm -rf $TEST_VENV"
        rlPhaseEnd
    else
        rlPhaseStartTest "Check type annotations against development packages"
            rlRun "pre-commit run --all-files mypy"
            rlRun "pre-commit run --all-files pyright"
        rlPhaseEnd
    fi

    rlPhaseStartCleanup
    rlPhaseEnd
rlJournalEnd