# Zerrow protocol operator entrypoints

-include .env
export

.PHONY: build test deploy configure-markets handoff-admin upgrade

build:
	forge build

test:
	npm test

deploy:
	./scripts/deploy-protocol.sh

configure-markets:
	./scripts/configure-markets.sh

handoff-admin:
	./scripts/handoff-admin.sh

upgrade:
	./scripts/upgrade-contract.sh $(TARGET)
