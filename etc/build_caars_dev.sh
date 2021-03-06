#!/bin/bash

set -euo pipefail +o nounset

### CAARS_DEV
IMAGE_NAME=caars_dev
DOCKERFILE_DIR=caars_dev
REPO=carinerey/$IMAGE_NAME
export BRANCH=`git branch | grep \* | cut -d ' ' -f2`
TAG=$BRANCH
docker build --no-cache --build-arg BRANCH_DEV=$BRANCH -t $REPO:$TAG $DOCKERFILE_DIR
push_flag=$1

if [[ $push_flag == "push_yes" ]]
then
    docker push $REPO:$TAG
fi
