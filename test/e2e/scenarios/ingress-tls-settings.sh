# shellcheck shell=bash
# TLS settings (see _ingress.sh, values/ingress.yaml): the chart-wide tls (TLS 1.2 at most)
# applies to the https listener, the internal listener's override (TLS 1.3 only) to that one;
# both share port 443, so the EnvoyFilter matches them by SNI. Each listener still serves its own
# certificate, which validates.
# shellcheck source=test/e2e/scenarios/_ingress.sh
source "${HERE}/scenarios/_ingress.sh"

install() {
  install_boundary minimal.yaml -f "$HERE/values/ingress.yaml"
}

extra() {
  client_ready
  local apps=(client/x https api.apps.e2e.test 443 --cacert "$CA")
  local internal=(client/x https api.internal.e2e.test 443 --cacert "$CA")
  check "chart-wide tls: TLS 1.2 connects" \
    retry connects "${apps[@]}" --tls-max 1.2 https://api.apps.e2e.test/
  check "chart-wide tls: TLS 1.3 is refused (maxVersion TLSv1_2)" \
    retry refused "${apps[@]}" --tlsv1.3 https://api.apps.e2e.test/
  check "listener override: TLS 1.3 connects" \
    retry connects "${internal[@]}" --tlsv1.3 https://api.internal.e2e.test/
  check "listener override: TLS 1.2 is refused (minVersion TLSv1_3)" \
    retry refused "${internal[@]}" --tls-max 1.2 https://api.internal.e2e.test/
  check "certificates still load: the https listener serves apps-tls" \
    subject_has "apps.e2e.test" "${apps[@]}" --tls-max 1.2 https://api.apps.e2e.test/
  check "certificates still load: the internal listener serves internal-tls" \
    subject_has "internal.e2e.test" "${internal[@]}" --tlsv1.3 https://api.internal.e2e.test/
}
