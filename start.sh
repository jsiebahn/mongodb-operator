#!/bin/bash

echo "🏗 Creating a local Docker registry …"
docker ps | grep kind-registry || docker run -d --restart=always -p "127.0.0.1:5000:5000" --name "kind-registry" registry:2 || exit 1

echo "🏗 Creating local Kubernetes cluster with KinD …"
kind get clusters | grep mongodb-operator-cluster || kind create cluster --config=local/setup/mongodb-operator-cluster.yaml || exit 1

echo "🏗 Connecting local Kubernetes cluster to local Docker registry …"
docker network inspect kind | grep "\"kind-registry\"" || docker network connect "kind" "kind-registry" || exit 1

echo "🏗 Installing infrastructure components in local Kubernetes cluster …"
# Need to apply without kustomize for GitHub Action that uses an older version of kustomize in kubectl
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml || exit 1
kubectl apply -f kustomize/overlays/infra/local-registry-hosting-cm.yaml || exit 1

echo "⏳ Waiting until Ingress Controller is ready …"
sleep 5
kubectl wait -n ingress-nginx --for=condition=ready pod -l=app.kubernetes.io/component=controller --timeout=180s || exit 1

echo "🏗 Installing MongoDB in local Kubernetes cluster …"
# Ingress fails sometimes at this point, something seems not to be ready
sleep 10
while [[ "FAILED" == $(kubectl apply -k kustomize/overlays/mongodb/ || echo -n "FAILED") ]]; do
  sleep 2
done

echo "⏳ Waiting for Mongoku to be ready …"
while [[ "FAILED" ==  $(curl -s http://localhost 2>/dev/null | grep "<title>" || echo -n "FAILED") ]]; do
  echo -n "."
  sleep 1
done
echo "."

echo "🏗 Build MongoDB operator and publish to connected registry …"
./gradlew jib -Djib.to.image=localhost:5000/mongodb-operator:local -Djib.allowInsecureRegistries=true || exit 1

echo "🏗 Installing MongoDB operator in local Kubernetes cluster …"
kubectl apply -k kustomize/overlays/operator/ || exit 1

echo "⏳ Wait for MongoDB operator to be ready …"
sleep 5
kubectl wait -n mongodb-operator --for=condition=ready pod -l=serverpod=mongodb-operator --timeout=180s || exit 1

echo "🏗 You can now install MongoDB custom resources and watch how secrets and databases are created by the operator:"
echo "   $ kubectl apply -k kustomize/overlays/test/"