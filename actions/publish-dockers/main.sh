#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi
DISTROS=${DISTROS:-}

set -euo pipefail

release_exists() {
  local source=$1
  releases=$(curl -s https://${source}.org/pypi/llama-stack/json | jq -r '.releases | keys[]')
  for release in $releases; do
    if [ x"$release" = x"$VERSION" ]; then
      return 0
    fi
  done
  return 1
}

if release_exists "test.pypi"; then
  echo "Version $VERSION found in test.pypi"
  PYPI_SOURCE="testpypi"
elif release_exists "pypi"; then
  echo "Version $VERSION found in pypi"
  PYPI_SOURCE="pypi"
else
  echo "Version $VERSION not found in either test.pypi or pypi" >&2
  exit 1
fi

set -x
TMPDIR=$(mktemp -d)
cd $TMPDIR
uv venv -p python3.12
source .venv/bin/activate

uv pip install --index-url https://test.pypi.org/simple/ \
  --extra-index-url https://pypi.org/simple \
  --index-strategy unsafe-best-match \
  llama-stack==${VERSION}

which llama
llama stack list-apis

build_and_push_docker() {
  distro=$1

  echo "Building and pushing docker for distro $distro"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    TEST_PYPI_VERSION=${VERSION} llama stack build --distro $distro --image-type container
  else
    PYPI_VERSION=${VERSION} llama stack build --distro $distro --image-type container
  fi

  TMP_BUILD_DIR=$(mktemp -d)
  CONTAINERFILE="$TMP_BUILD_DIR/Containerfile"
  cat > "$CONTAINERFILE" << EOF
FROM distribution-$distro:$( [ "$PYPI_SOURCE" = "testpypi" ] && echo "test-${VERSION}" || echo "${VERSION}" )
USER root

# Create group with GID 1001 and user with UID 1001
RUN groupadd -g 1001 appgroup && useradd -u 1001 -g appgroup -M appuser

# Create necessary directories with appropriate permissions for UID 1001
RUN mkdir -p /.llama /.cache && chown -R 1001:1001 /.llama /.cache && chmod -R 775 /.llama /.cache && chmod -R g+w /app

# Set the Llama Stack config directory environment variable to use /.llama
ENV LLAMA_STACK_CONFIG_DIR=/.llama
ENV HOME=/

USER 1001
EOF

  docker build -t distribution-$distro:$( [ "$PYPI_SOURCE" = "testpypi" ] && echo "test-${VERSION}" || echo "${VERSION}" ) -f "$CONTAINERFILE" "$TMP_BUILD_DIR"
  rm -rf "$TMP_BUILD_DIR"

  docker images | cat

  echo "Pushing docker image"
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    docker tag distribution-$distro:test-${VERSION} llamastack/distribution-$distro:test-${VERSION}
    docker push llamastack/distribution-$distro:test-${VERSION}
  else
    docker tag distribution-$distro:${VERSION} llamastack/distribution-$distro:${VERSION}
    docker tag distribution-$distro:${VERSION} llamastack/distribution-$distro:latest
    docker push llamastack/distribution-$distro:${VERSION}
    docker push llamastack/distribution-$distro:latest
  fi
}

if [ -z "$DISTROS" ]; then
  DISTROS=(starter meta-reference-gpu postgres-demo dell starter-gpu)
else
  DISTROS=(${DISTROS//,/ })
fi

for distro in "${DISTROS[@]}"; do
  build_and_push_docker $distro
done

echo "Done"
