#!/bin/sh
# Xcode Cloud: make the Xcode project from project.yml before building (the project isn't kept in git).
set -e
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
