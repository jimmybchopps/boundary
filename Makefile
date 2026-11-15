# Pinned tool versions. CI reads these too; change them here only.
HELM_VERSION          ?= 4.3.1
HELM_MIN_VERSION      := 3.14.4
HELM3_LATEST_VERSION  := 3.22.1
HELM_UNITTEST_VERSION := 1.2.1
# helm-unittest 1.1.0+ uses plugin.yaml fields (platformHooks) that Helm 3.14 can't parse;
# 1.0.3 is the last release it loads.
HELM_UNITTEST_LEGACY_VERSION := 1.0.3
KUBECONFORM_VERSION   := 0.8.0
K3D_VERSION           := 5.9.0
KUBECTL_VERSION       := 1.37.2
# e2e (test/e2e/run.sh)
K3S_IMAGE             := rancher/k3s:v1.37.2-k3s1
# Calico for the integration cluster (test/e2e/integration.sh), which needs NetworkPolicy
# enforced: posture's egress NetworkPolicies are what keep a namespace that didn't ask for a
# host off it. The same version as posture's harness.
CALICO_VERSION        := 3.29.0
# Istio Helm chart version for the e2e cluster (install_istio in test/e2e/lib.sh); istioctl
# matches it and is used only to inspect a failing cluster.
ISTIO_VERSION         := 1.32.0
ISTIOCTL_VERSION      := $(ISTIO_VERSION)
# Every image the e2e runs is pinned by digest (the policy chart's require-image-digest, enforced
# in the integration run): the multi-arch index digest of each tag.
AGNHOST_IMAGE         := registry.k8s.io/e2e-test-images/agnhost:2.61@sha256:101f3357d1ad890c3090e78ea6c6a47dc5137cbe19836796e13d5dcb2b84d2e6
CURL_IMAGE            := docker.io/curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93
# Istio's images for ISTIO_VERSION, distroless (the ambient profile's variant), as full
# references: istiod (pilot.image), the gateway and waypoint proxies (global.proxy.image), and
# ztunnel (image). istio-cni runs in kube-system, which the policy chart never evaluates.
ISTIO_PILOT_IMAGE     := docker.io/istio/pilot:$(ISTIO_VERSION)-distroless@sha256:219ab7efcf1fd1f883086ad4a4a649c0e70bee3200423d6eef9f435103a79423
ISTIO_PROXY_IMAGE     := docker.io/istio/proxyv2:$(ISTIO_VERSION)-distroless@sha256:9cd1f1cc261f3fe250ab483543e7256c39d5871eae5f1817c0809eff09e365d4
ISTIO_ZTUNNEL_IMAGE   := docker.io/istio/ztunnel:$(ISTIO_VERSION)-distroless@sha256:953a77fc17379301de4b7c6697b1668471c9c1f6ff912c9c5b78f454ab362180
MESH                  ?= istio
# The Gateway API CRDs (standard channel) the chart requires; also in Chart.yaml's annotations.
GATEWAY_API_VERSION   := 1.6.0
GATEWAY_API_SHA256    := a557172e8348f758479e9ee4000bbbb4b4aa48302a6b73461823ea5349bad56d
# The posture release installed in every e2e namespace (0.2.0+: the gateway profiles' exceptions
# for Istio's own pods), and the policy release: its PolicyExceptions CRD, which every posture
# install needs, and its chart, which the integration run enforces (0.2.0+:
# restrict-route-hostnames). Checksums from each release's SHA256SUMS; bump version and
# checksum together.
POSTURE_VERSION       := 0.2.0
POSTURE_CHART_SHA256  := 02d1ef08cbead120b2673dfb7eb42813f2d6050307fea07280b3803cefccc724
POLICY_VERSION        := 0.2.1
POLICY_CRD_SHA256     := 0b1c6cba6754d0135454d6f7f737f49b7f833f4ee0e7d37315654117821781be
POLICY_CHART_SHA256   := 20a1d1789fc954f59192c9ca6d23a03db3e3531ab4080f60a7bc74e3a20c6e70

# Every Helm version this chart supports; `make test-all-helm` runs the suite under each.
HELM_VERSIONS := $(HELM_MIN_VERSION) $(HELM3_LATEST_VERSION) $(HELM_VERSION)

CHART    := charts/boundary
# Test-only chart that renders boundary's model so tests can assert on it (test/model-probe).
PROBE    := test/model-probe
EXAMPLES := $(wildcard examples/*.yaml)
CRDS_CATALOG := https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json

OS   := $(shell uname -s | tr '[:upper:]' '[:lower:]')
ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

BIN       := $(CURDIR)/.bin
HELM_HOME := $(BIN)/helm-$(HELM_VERSION)
HELM      := $(HELM_HOME)/helm
KUBECONFORM := $(BIN)/kubeconform-$(KUBECONFORM_VERSION)
K3D       := $(BIN)/k3d-$(K3D_VERSION)
KUBECTL   := $(BIN)/kubectl-$(KUBECTL_VERSION)
ISTIOCTL  := $(BIN)/istioctl-$(ISTIOCTL_VERSION)

# Each Helm version gets its own plugin, cache, config, and data directories, so Helm 3 and
# Helm 4 never share plugin installs.
export HELM_PLUGINS     := $(HELM_HOME)/plugins
export HELM_CACHE_HOME  := $(HELM_HOME)/cache
export HELM_CONFIG_HOME := $(HELM_HOME)/config
export HELM_DATA_HOME   := $(HELM_HOME)/data

# Pinned downloads for the e2e cluster (make e2e-deps), checked against the checksums above.
GATEWAY_API_CRDS := $(BIN)/gateway-api-$(GATEWAY_API_VERSION)/standard-install.yaml
POSTURE_CHART    := $(BIN)/posture-$(POSTURE_VERSION)/posture-$(POSTURE_VERSION).tgz
POLICY_CRD       := $(BIN)/policy-$(POLICY_VERSION)/policy.posture.dev_policyexceptions.yaml
POLICY_CHART     := $(BIN)/policy-$(POLICY_VERSION)/policy-$(POLICY_VERSION).tgz

UNITTEST_PLUGIN := $(HELM_PLUGINS)/helm-unittest
UNITTEST_VERSION := $(if $(filter 3.14.%,$(HELM_VERSION)),$(HELM_UNITTEST_LEGACY_VERSION),$(HELM_UNITTEST_VERSION))
# helm-unittest only reads tests/*_test.yaml by default; the suites are grouped by output in
# subfolders (tests/istio/), so name both levels.
UNITTEST_FILES := -f 'tests/*_test.yaml' -f 'tests/*/*_test.yaml'

.PHONY: help tools tools-e2e e2e-deps lint unittest unittest-update validate test test-all-helm e2e e2e-integration clean

help:
	@echo "make tools          install helm $(HELM_VERSION), helm-unittest, kubeconform into .bin/"
	@echo "make test           lint, unittest, validate"
	@echo "make test-all-helm  make test under Helm $(HELM_VERSIONS)"
	@echo "make e2e            k3d end-to-end tests (MESH=istio, E2E_ARGS=<scenario>, E2E_KEEP=1)"
	@echo "make e2e-integration  the full stack (policy, Istio, posture, boundary) on one cluster"
	@echo "make unittest-update  regenerate example snapshots (review the diff)"
	@echo "HELM_VERSION=x.y.z selects the Helm version for any target."

tools: $(HELM) $(UNITTEST_PLUGIN) $(KUBECONFORM)

tools-e2e: $(K3D) $(KUBECTL) $(ISTIOCTL)

$(HELM):
	mkdir -p $(HELM_HOME)
	curl -fsSL https://get.helm.sh/helm-v$(HELM_VERSION)-$(OS)-$(ARCH).tar.gz \
	  | tar -xz -C $(HELM_HOME) --strip-components=1 $(OS)-$(ARCH)/helm

# Helm 4 verifies plugin sources by default and helm-unittest isn't signed; Helm 3 has no
# --verify flag at all.
$(UNITTEST_PLUGIN): $(HELM)
	$(HELM) plugin install https://github.com/helm-unittest/helm-unittest \
	  --version $(UNITTEST_VERSION) \
	  $(if $(filter 4.%,$(HELM_VERSION)),--verify=false)

$(KUBECONFORM):
	mkdir -p $(BIN)
	curl -fsSL https://github.com/yannh/kubeconform/releases/download/v$(KUBECONFORM_VERSION)/kubeconform-$(OS)-$(ARCH).tar.gz \
	  | tar -xz -O kubeconform > $@
	chmod +x $@

$(K3D):
	mkdir -p $(BIN)
	curl -fsSL -o $@ https://github.com/k3d-io/k3d/releases/download/v$(K3D_VERSION)/k3d-$(OS)-$(ARCH)
	chmod +x $@

$(KUBECTL):
	mkdir -p $(BIN)
	curl -fsSL -o $@ https://dl.k8s.io/release/v$(KUBECTL_VERSION)/bin/$(OS)/$(ARCH)/kubectl
	chmod +x $@

$(ISTIOCTL):
	mkdir -p $(BIN)
	curl -fsSL https://github.com/istio/istio/releases/download/$(ISTIOCTL_VERSION)/istioctl-$(ISTIOCTL_VERSION)-$(OS)-$(ARCH).tar.gz \
	  | tar -xz -O istioctl > $@
	chmod +x $@

# Downloads are checked against the pinned checksums, so a moved tag can't change what's tested.
e2e-deps: $(GATEWAY_API_CRDS) $(POSTURE_CHART) $(POLICY_CRD) $(POLICY_CHART)

$(GATEWAY_API_CRDS):
	mkdir -p $(dir $@)
	curl -fsSL -o $@.tmp https://github.com/kubernetes-sigs/gateway-api/releases/download/v$(GATEWAY_API_VERSION)/standard-install.yaml
	echo "$(GATEWAY_API_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

$(POSTURE_CHART):
	mkdir -p $(dir $@)
	curl -fsSL -o $@.tmp https://github.com/jimmybchopps/posture/releases/download/v$(POSTURE_VERSION)/$(notdir $@)
	echo "$(POSTURE_CHART_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

$(POLICY_CRD):
	mkdir -p $(dir $@)
	curl -fsSL -o $@.tmp https://github.com/jimmybchopps/policy/releases/download/v$(POLICY_VERSION)/$(notdir $@)
	echo "$(POLICY_CRD_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

$(POLICY_CHART):
	mkdir -p $(dir $@)
	curl -fsSL -o $@.tmp https://github.com/jimmybchopps/policy/releases/download/v$(POLICY_VERSION)/$(notdir $@)
	echo "$(POLICY_CHART_SHA256)  $@.tmp" | sha256sum -c --quiet
	mv $@.tmp $@

lint: $(HELM)
	$(HELM) lint --strict $(CHART)
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> helm lint --strict -f $$f"; \
	  $(HELM) lint --strict $(CHART) -f $$f; \
	done

unittest: $(UNITTEST_PLUGIN)
	$(HELM) dependency update --skip-refresh $(PROBE) >/dev/null
	$(HELM) unittest $(UNITTEST_FILES) $(CHART) $(PROBE)

# Regenerate the example snapshots after an intended change; review the diff before committing.
unittest-update: $(UNITTEST_PLUGIN)
	$(HELM) unittest -u $(UNITTEST_FILES) $(CHART)

validate: $(HELM) $(KUBECONFORM)
	@set -e; for f in $(EXAMPLES); do \
	  echo "==> kubeconform $$f"; \
	  $(HELM) template boundary $(CHART) -f $$f \
	    | $(KUBECONFORM) -strict -summary \
	        -schema-location default -schema-location '$(CRDS_CATALOG)'; \
	done

test: lint unittest validate

test-all-helm:
	@set -e; for v in $(HELM_VERSIONS); do \
	  echo "==> Helm $$v"; \
	  $(MAKE) --no-print-directory test HELM_VERSION=$$v; \
	done

# Needs Docker. Extra arguments go to run.sh via E2E_ARGS (e.g. E2E_ARGS=mtls-strict).
E2E_ENV = K3D=$(K3D) KUBECTL=$(KUBECTL) HELM=$(HELM) ISTIOCTL=$(ISTIOCTL) \
	K3S_IMAGE=$(K3S_IMAGE) CALICO_VERSION=$(CALICO_VERSION) ISTIO_VERSION=$(ISTIO_VERSION) \
	ISTIO_PILOT_IMAGE=$(ISTIO_PILOT_IMAGE) ISTIO_PROXY_IMAGE=$(ISTIO_PROXY_IMAGE) \
	ISTIO_ZTUNNEL_IMAGE=$(ISTIO_ZTUNNEL_IMAGE) \
	AGNHOST_IMAGE=$(AGNHOST_IMAGE) CURL_IMAGE=$(CURL_IMAGE) \
	GATEWAY_API_CRDS=$(GATEWAY_API_CRDS) POSTURE_CHART=$(POSTURE_CHART) \
	POLICY_CRD=$(POLICY_CRD) POLICY_CHART=$(POLICY_CHART)

e2e: $(HELM) tools-e2e e2e-deps
	$(E2E_ENV) test/e2e/run.sh $(MESH) $(E2E_ARGS)

# Needs Docker. Every component on one cluster, in the documented install order, with the
# policy chart's defaults enforced (test/e2e/integration.sh).
e2e-integration: $(HELM) tools-e2e e2e-deps
	$(E2E_ENV) test/e2e/integration.sh $(MESH)

clean:
	rm -rf $(BIN)
