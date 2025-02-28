#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi

TEMPLATES=${TEMPLATES:-}
IS_NIGHTLY=false

if [[ "$VERSION" == nightly-* ]]; then
  IS_NIGHTLY=true
fi

set -euo pipefail

# Common setup for both scripts
if [ "$IS_NIGHTLY" = true ]; then
  cd llama-stack
fi

set -x
uv venv -p python3.10
source .venv/bin/activate

if [ "$IS_NIGHTLY" = true ]; then
  pip install -U .
else
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

  uv pip install --index-url https://test.pypi.org/simple/ \
    --extra-index-url https://pypi.org/simple \
    --index-strategy unsafe-best-match \
    llama-stack==${VERSION} llama-models==${VERSION} llama-stack-client==${VERSION}
fi

which llama
llama stack list-apis

build_and_push_docker() {
  template=$1

  echo "Building and pushing docker for template $template"

  if [ "$IS_NIGHTLY" = true ]; then
    USE_COPY_NOT_MOUNT=true LLAMA_STACK_DIR=. llama stack build --template $template --image-type container
  else
    if [ "$PYPI_SOURCE" = "testpypi" ]; then
      TEST_PYPI_VERSION=${VERSION} llama stack build --template $template --image-type container
    else
      PYPI_VERSION=${VERSION} llama stack build --template $template --image-type container
    fi
  fi

  docker images

  echo "Pushing docker image"
  if [ "$IS_NIGHTLY" = true ]; then
    docker tag distribution-$template:dev llamastack/distribution-$template:${VERSION}
    docker push llamastack/distribution-$template:${VERSION}
  else
    if [ "$PYPI_SOURCE" = "testpypi" ]; then
      docker tag distribution-$template:test-${VERSION} llamastack/distribution-$template:test-${VERSION}
      docker push llamastack/distribution-$template:test-${VERSION}
    else
      docker tag distribution-$template:${VERSION} llamastack/distribution-$template:${VERSION}
      docker tag distribution-$template:${VERSION} llamastack/distribution-$template:latest
      docker push llamastack/distribution-$template:${VERSION}
      docker push llamastack/distribution-$template:latest
    fi
  fi
}

if [ -z "$TEMPLATES" ]; then
  TEMPLATES=(ollama together fireworks bedrock remote-vllm tgi meta-reference-gpu)
else
  TEMPLATES=(${TEMPLATES//,/ })
fi

for template in "${TEMPLATES[@]}"; do
  build_and_push_docker $template
done

echo "Done"
