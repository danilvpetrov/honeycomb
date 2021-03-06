SHELL := /bin/bash

DOCKER_REPO ?= icecave/honeycomb
DOCKER_TAG  ?= dev

CGO_ENABLED = 0

REQ := $(patsubst res/assets/%,artifacts/assets/%.go, $(wildcard res/assets/*))
CERTIFICATES := $(addprefix artifacts/certificates/honeycomb-,ca.crt ca.key server.crt server.key)

CERTIFICATE_PATH ?= artifacts/certificates

-include artifacts/make/go.mk

.PHONY: run
run: $(BUILD_PATH)/debug/$(CURRENT_OS)/$(CURRENT_ARCH)/honeycomb $(CERTIFICATES)
	CERTIFICATE_PATH=$(CERTIFICATE_PATH) \
		$(BUILD_PATH)/debug/$(CURRENT_OS)/$(CURRENT_ARCH)/honeycomb

.PHONY: docker
docker: artifacts/docker-$(DOCKER_TAG).touch

.PHONY: publish
publish: docker
	docker push "$(DOCKER_REPO):$(DOCKER_TAG)"

.PHONY: docker-services
docker-services: docker
	-docker service rm honeycomb honeycomb-echo
	-docker network create --driver=overlay public
	docker service create \
		--name honeycomb \
		--publish 80:8080 \
		--publish 443:8443 \
		--constraint node.role==manager \
		--mount type=bind,target=/var/run/docker.sock,source=/var/run/docker.sock \
		--secret honeycomb-ca.crt \
		--secret honeycomb-ca.key \
		--secret honeycomb-server.crt \
		--secret honeycomb-server.key \
		--network public \
		icecave/honeycomb:dev
	docker service create \
		--name honeycomb-echo \
		--network public \
		--label 'honeycomb.match=echo.*' \
		jmalloc/echo-server

MINIFY := $(GOPATH)/bin/minify
$(MINIFY):
	go get -u github.com/tdewolff/minify/cmd/minify

artifacts/assets/%.tmp: res/assets/% | $(MINIFY)
	$(MINIFY) -o "$@" "$<" || cp "$<" "$@"

artifacts/assets/%.go: artifacts/assets/%.tmp
	@mkdir -p "$(@D)"
	@echo "package assets" > "$@"
	@echo 'const $(shell echo $(notdir $*) | tr [:lower:] [:upper:] | tr . _) = `' >> "$@"
	cat "$<" >> "$@"
	@echo '`' >> "$@"

artifacts/certificates/%.key:
	@mkdir -p "$(@D)"
	openssl genrsa -out "$@" 2048

artifacts/certificates/%.csr.tmp: artifacts/certificates/%.key
	openssl req \
		-new \
		-sha256 \
		-subj "/CN=Honeycomb Default Certificate/subjectAltName=DNS.1=*" \
		-key "$<" \
		-out "$@"

artifacts/certificates/honeycomb-ca.crt: artifacts/certificates/honeycomb-ca.key
	openssl req \
		-new \
		-x509 \
		-sha256 \
		-days 30 \
		-extensions v3_ca \
		-nodes \
		-subj "/CN=Honeycomb CA" \
		-key "$<" \
		-out "$@"

artifacts/certificates/%.crt: artifacts/certificates/%.csr.tmp artifacts/certificates/extensions.cnf.tmp artifacts/certificates/honeycomb-ca.crt artifacts/certificates/honeycomb-ca.key
	openssl x509 \
		-req \
		-sha256 \
		-days 30 \
		-extfile artifacts/certificates/extensions.cnf.tmp \
		-CA artifacts/certificates/honeycomb-ca.crt \
		-CAkey artifacts/certificates/honeycomb-ca.key \
		-CAcreateserial \
		-in "$<" \
		-out "$@"

artifacts/certificates/extensions.cnf.tmp:
	echo "extendedKeyUsage = serverAuth" > "$@"

artifacts/docker-$(DOCKER_TAG).touch: Dockerfile artifacts/cacert.pem $(addprefix $(BUILD_PATH)/release/linux/amd64/,$(BINARIES))
	docker build -t "$(DOCKER_REPO):$(DOCKER_TAG)" .
	touch "$@"

artifacts/make/%.mk:
	bash <(curl -s https://icecave.github.io/make/install) $*

# artifacts/build/Makefile.in:
# mkdir -p "$(@D)"
# curl -Lo "$(@D)/runtime.go" https://raw.githubusercontent.com/icecave/make/master/go/runtime.go
# curl -Lo "$@" https://raw.githubusercontent.com/icecave/make/master/go/Makefile.in

artifacts/cabundle/gd_bundle-g2-g1.crt:
	@mkdir -p "$(@D)"
	curl -L -o "$@" https://certs.godaddy.com/repository/gd_bundle-g2-g1.crt

artifacts/cabundle/comodo_dv_sha-256_bundle.crt.zip:
	@mkdir -p "$(@D)"
	curl -L -o "$@" https://namecheap.simplekb.com/SiteContents/2-7C22D5236A4543EB827F3BD8936E153E/media/COMODO_DV_SHA-256_bundle.crt.zip

artifacts/cabundle/COMODO_DV_SHA-256_bundle.crt: artifacts/cabundle/comodo_dv_sha-256_bundle.crt.zip
	unzip -o artifacts/cabundle/comodo_dv_sha-256_bundle.crt.zip -d "$(@D)"
	touch -c "$@"

artifacts/cacert.pem: artifacts/cabundle/gd_bundle-g2-g1.crt artifacts/cabundle/COMODO_DV_SHA-256_bundle.crt
	curl -L -o "$@.orig" http://curl.haxx.se/ca/cacert.pem
	cat "$@.orig" > "$@"
	( echo ""; echo "Go Daddy Intermediates"; echo "=================="; cat artifacts/cabundle/gd_bundle-g2-g1.crt ) >> "$@"
	( echo ""; echo "Comodo PositiveSSL Intermediates"; echo "=================="; cat artifacts/cabundle/COMODO_DV_SHA-256_bundle.crt ) >> "$@"
