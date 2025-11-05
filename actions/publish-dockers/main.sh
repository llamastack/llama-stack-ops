#!/bin/bash

if [ -z "$VERSION" ]; then
  echo "You must set the VERSION environment variable" >&2
  exit 1
fi
DISTROS=${DISTROS:-}
INCLUDE_UI_IMAGE=${INCLUDE_UI_IMAGE:-true}

set -euo pipefail

is_truthy() {
  case "$1" in
  true | 1 | yes | on) return 0 ;;
  false | 0 | no | off) return 1 ;;
  *) return 1 ;;
  esac
}

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
  
  # Clone llama-stack repo to get the Containerfile
  LLAMA_STACK_DIR=$(mktemp -d)
  git clone --depth 1 https://github.com/llamastack/llama-stack.git "$LLAMA_STACK_DIR"
  
  # Determine the tag suffix and build args based on PyPI source
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    TAG_SUFFIX="test-${VERSION}"
    docker build "$LLAMA_STACK_DIR" \
      -f "$LLAMA_STACK_DIR/containers/Containerfile" \
      --build-arg DISTRO_NAME=$distro \
      --build-arg INSTALL_MODE=test-pypi \
      --build-arg TEST_PYPI_VERSION=${VERSION} \
      -t distribution-$distro:$TAG_SUFFIX
  else
    TAG_SUFFIX="${VERSION}"
    docker build "$LLAMA_STACK_DIR" \
      -f "$LLAMA_STACK_DIR/containers/Containerfile" \
      --build-arg DISTRO_NAME=$distro \
      --build-arg PYPI_VERSION=${VERSION} \
      -t distribution-$distro:$TAG_SUFFIX
  fi

  rm -rf "$LLAMA_STACK_DIR"

  # Build a second layer for OpenShift compatibility
  TMP_BUILD_DIR=$(mktemp -d)
  CONTAINERFILE="$TMP_BUILD_DIR/Containerfile"
  cat > "$CONTAINERFILE" << EOF
FROM distribution-$distro:$TAG_SUFFIX
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

  docker build -t distribution-$distro:$TAG_SUFFIX -f "$CONTAINERFILE" "$TMP_BUILD_DIR"
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

build_and_push_ui_docker_image() {
  local version=$1

  if ! command -v docker &>/dev/null; then
    echo "docker CLI is required to publish llamastack/ui" >&2
    exit 1
  fi

  local tag_suffix
  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    tag_suffix="test-${version}"
  else
    tag_suffix="${version}"
  fi

  (
    set -euo pipefail
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' EXIT

    cat > "$tmp_dir/Containerfile" <<'EOF'
ARG UI_VERSION
FROM node:22.5.1-alpine

ENV NODE_ENV=production

# Install dumb-init for proper signal handling
RUN apk add --no-cache dumb-init

# Create non-root user for security
RUN addgroup --system --gid 1001 nodejs
RUN adduser --system --uid 1001 nextjs

# Install the UI package from npm
RUN npm install -g "llama-stack-ui@${UI_VERSION}"

USER nextjs

ENTRYPOINT ["dumb-init", "--"]
CMD ["llama-stack-ui"]
EOF

    docker build \
      --build-arg UI_VERSION="$version" \
      -t "llamastack/ui:${tag_suffix}" \
      -f "$tmp_dir/Containerfile" \
      "$tmp_dir"
  )

  if [ "$PYPI_SOURCE" = "testpypi" ]; then
    docker push "llamastack/ui:${tag_suffix}"
  else
    docker tag "llamastack/ui:${tag_suffix}" "llamastack/ui:latest"
    docker push "llamastack/ui:${tag_suffix}"
    docker push "llamastack/ui:latest"
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

if is_truthy "$INCLUDE_UI_IMAGE"; then
  build_and_push_ui_docker_image "$VERSION"
else
  echo "Skipping UI docker image publish (INCLUDE_UI_IMAGE=$INCLUDE_UI_IMAGE)"
fi

echo "Done"
