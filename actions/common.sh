# Copyright (c) Meta Platforms, Inc. and affiliates.
# All rights reserved.
#
# This source code is licensed under the terms described in the LICENSE file in
# the root directory of this source tree.

github_org() {
  echo "llamastack"
}

run_integration_tests() {
  stack_config=$1

  # Point to recordings in the git checkout, not the installed wheel
  # This is necessary because wheels don't include test recordings
  export LLAMA_STACK_TEST_RECORDING_DIR="$(pwd)/llama-stack/tests/integration/common"

  echo "Running integration tests (text)"
  bash llama-stack/scripts/integration-tests.sh \
    --stack-config $stack_config \
    --inference-mode replay \
    --suite base \
    --setup ollama

  echo "Running integration tests (vision)"
  bash llama-stack/scripts/integration-tests.sh \
    --stack-config $stack_config \
    --inference-mode replay \
    --suite vision \
    --setup ollama
}

install_dependencies() {
  uv pip install pytest pytest-asyncio
}

test_llama_cli() {
  uv pip list | grep llama
  llama stack list-apis > /dev/null
}
