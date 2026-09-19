# Host OS picks the Flutter device; override with `make run OS=linux`.
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  OS ?= macos
else ifeq ($(UNAME),Linux)
  OS ?= linux
else
  OS ?= windows
endif

VERSION := $(shell sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
DEFINES := --dart-define=APP_VERSION=$(VERSION)

.DEFAULT_GOAL := help
.PHONY: help deps build run test analyze clean

help: ## Show this help
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F ':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

deps: ## Fetch Dart packages
	flutter pub get

build: deps ## Release build for $(OS)
	flutter build $(OS) --release $(DEFINES)

run: deps ## Run on $(OS)
	flutter run -d $(OS) $(DEFINES)

test: deps ## Run tests (builds a local libserialport so SLCAN tests run for real)
	@[ -f build/test/libserialport.$(if $(filter Darwin,$(UNAME)),dylib,so) ] || \
		tools/build-test-libserialport.sh
	LIBSERIALPORT_PATH=$(CURDIR)/build/test/libserialport.$(if $(filter Darwin,$(UNAME)),dylib,so) \
		flutter test --coverage

analyze: deps ## Static analysis
	flutter analyze

clean: ## Remove build output
	flutter clean
