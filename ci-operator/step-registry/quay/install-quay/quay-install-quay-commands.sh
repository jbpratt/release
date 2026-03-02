#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Waiting for NooBaa CRD to be available..." >&2
for i in $(seq 1 60); do
    if oc get crd noobaas.noobaa.io &>/dev/null; then
        echo "NooBaa CRD available" >&2
        break
    fi
    if (( i == 60 )); then
        echo "Timed out waiting for NooBaa CRD" >&2
        exit 1
    fi
    sleep 5
done

cat <<EOF | oc apply -f -
apiVersion: noobaa.io/v1alpha1
kind: NooBaa
metadata:
  name: noobaa
  namespace: openshift-storage
spec:
  dbResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
  coreResources:
    requests:
      cpu: '0.1'
      memory: 1Gi
EOF

echo "Waiting for NooBaa storage..." >&2
oc -n openshift-storage wait noobaa.noobaa.io/noobaa --for=condition=Available --timeout=120s

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay
EOF

oc -n quay create secret generic quay-config-bundle \
    --from-literal=config.yaml=$'FEATURE_USER_INITIALIZE: true\nSUPER_USERS:\n- admin\n'

cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay
spec:
  configBundleSecret: quay-config-bundle
  components:
  - kind: clair
    managed: true
EOF

echo "Waiting for Quay to become ready (timeout: 15m)..." >&2
for i in $(seq 1 90); do
    status="$(oc -n quay get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
    if [[ "$status" == "True" ]]; then
        echo "Quay is ready (after $((i * 10))s)" >&2

        registryEndpoint="$(oc -n quay get quayregistry quay -o jsonpath='{.status.registryEndpoint}')"

        echo "Creating admin user via API..." >&2
        init_response=$(curl -sk -X POST "${registryEndpoint}/api/v1/user/initialize" \
            -H 'Content-Type: application/json' \
            -d '{"username": "admin", "password": "p@ssw0rd", "email": "admin@localhost.local", "access_token": true}')

        access_token=$(echo "$init_response" | grep -o '"access_token" *: *"[^"]*"' | head -1 | sed 's/.*: *"//;s/"$//')
        if [[ -z "$access_token" ]]; then
            echo "Failed to initialize admin user. Response: $init_response" >&2
            exit 1
        fi
        echo "Admin user created successfully" >&2

        echo "Creating organization and OAuth application..." >&2
        curl -sk -X POST "${registryEndpoint}/api/v1/organization/" \
            -H 'Content-Type: application/json' \
            -H "Authorization: Bearer ${access_token}" \
            -d '{"name": "quay-bridge-operator", "email": "quay-bridge-operator@localhost.local"}'

        curl -sk -X POST "${registryEndpoint}/api/v1/organization/quay-bridge-operator/applications" \
            -H 'Content-Type: application/json' \
            -H "Authorization: Bearer ${access_token}" \
            -d '{"name": "quay-bridge-operator", "redirect_uri": "", "application_uri": ""}'

        printf "%s" "$access_token" >"$SHARED_DIR/quay-access-token"
        echo "Quay install and admin setup complete" >&2
        exit 0
    fi
    if (( i % 6 == 0 )); then
        echo "[$((i * 10))s] Quay not ready yet. Component status:" >&2
        oc -n quay get quayregistry quay -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' 2>/dev/null >&2 || true
    fi
    sleep 10
done

echo "Timed out waiting for Quay to become ready" >&2
echo "Final QuayRegistry conditions:" >&2
oc -n quay get quayregistry quay -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' 2>/dev/null >&2 || true
echo "Pods in quay namespace:" >&2
oc -n quay get pods -o wide >&2 || true
echo "Events in quay namespace:" >&2
oc -n quay get events --sort-by='.lastTimestamp' >&2 || true

oc -n quay get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
oc -n quay get pods -o yaml >"$ARTIFACT_DIR/quay-pods.yaml" || true
oc -n quay get events --sort-by='.lastTimestamp' -o yaml >"$ARTIFACT_DIR/quay-events.yaml" || true
oc -n quay get deployments -o yaml >"$ARTIFACT_DIR/quay-deployments.yaml" || true
exit 1
