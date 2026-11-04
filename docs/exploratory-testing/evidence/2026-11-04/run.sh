#!/bin/sh
set -eu
cd "$(git rev-parse --show-toplevel)"
export PASS_NAME="beanstalk-explore-20261104-$$"
export PASS_IMAGE="local/$PASS_NAME:explore"
BUILDER="$PASS_NAME-builder"
BUILD_IMAGE=moby/buildkit:buildx-stable-1
existing_build_image=$(docker image inspect "$BUILD_IMAGE" --format '{{.Id}}' 2>/dev/null || true)
cleanup() {
    docker rm -f -v "$PASS_NAME" >/dev/null 2>&1 || true
    docker volume rm "$PASS_NAME" >/dev/null 2>&1 || true
    docker image rm "$PASS_IMAGE" >/dev/null 2>&1 || true
    docker buildx rm "$BUILDER" >/dev/null 2>&1 || true
    if [ -z "$existing_build_image" ]; then
        docker image rm "$BUILD_IMAGE" >/dev/null 2>&1 || true
    fi
    echo "Cleanup verification for $PASS_NAME"
    docker ps -a --filter "name=^/$PASS_NAME$" --format '{{.Names}}'
    docker volume ls --filter "name=^$PASS_NAME$" --format '{{.Name}}'
    docker image ls "$PASS_IMAGE" --format '{{.Repository}}:{{.Tag}}'
    docker buildx ls | grep "$BUILDER" || true
    docker ps -a --filter "name=buildx_buildkit_$BUILDER" --format '{{.Names}}'
    docker volume ls --filter "name=buildx_buildkit_$BUILDER" --format '{{.Name}}'
}
trap cleanup EXIT HUP INT TERM
printf 'Registered container and volume %s, image %s, builder %s\n' "$PASS_NAME" "$PASS_IMAGE" "$BUILDER"
docker buildx create --name "$BUILDER" --driver docker-container >/dev/null
docker buildx build --builder "$BUILDER" --no-cache --load -t "$PASS_IMAGE" .
python3 docs/exploratory-testing/evidence/2026-11-04/journeys.py
