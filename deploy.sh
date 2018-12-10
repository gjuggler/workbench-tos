#!/usr/bin/env bash
set -e
set -x

VAULT_TOKEN=$1
GIT_BRANCH=$2   # github branch of the code to deploy
ENVIRONMENT=$3  # hosting environment which the deploy will target
PROJECT=$4      # Full project name to deploy to; optional.
VAULT_ADDR=$5

set +x
if [ -z "$ENVIRONMENT" ]; then
    echo "ENVIRONMENT argument not supplied; inferring from GIT_BRANCH '$GIT_BRANCH'."
    if [ "$GIT_BRANCH" == "develop" ]; then
        ENVIRONMENT="dev"
    elif [ "$GIT_BRANCH" == "alpha" ]; then
        ENVIRONMENT="alpha"
    elif [ "$GIT_BRANCH" == "perf" ]; then
        ENVIRONMENT="perf"
    elif [ "$GIT_BRANCH" == "staging" ]; then
        ENVIRONMENT="staging"
    elif [ "$GIT_BRANCH" == "master" ]; then
        ENVIRONMENT="prod"
    else
        echo "Git branch '$GIT_BRANCH' is not configured to automatically deploy to a target environment"
        exit 1
    fi
elif [[ "$ENVIRONMENT" =~ ^(fiab|dev|alpha|perf|staging|prod)$ ]]; then
    echo "ENVIRONMENT argument supplied as '$ENVIRONMENT'"
else
    echo "Environment '$ENVIRONMENT' is not supported for deployments via this script."
    exit 1
fi

if [ -z "$PROJECT" ]; then
  PROJECT_NAME="broad-workbench-tos-${ENVIRONMENT}"
else
  echo "PROJECT argument has been specified; deploying to project $PROJECT."
  PROJECT_NAME=${PROJECT}
fi

echo "Deploying branch '$GIT_BRANCH' to environment '$ENVIRONMENT' and project '$PROJECT_NAME'"

set -x

SERVICE_ACCT_KEY_FILE="deploy_account.json"

if [[ "$ENVIRONMENT" =~ ^(fiab)$ ]]; then
  DEPLOY_KEY_PATH="secret/dsde/firecloud/fiab/common/firecloud-account.json"
else
  DEPLOY_KEY_PATH="secret/dsde/firecloud/${ENVIRONMENT}/tos/deploy-sa"
fi

# Get the environment-specific credentials for the service account out of Vault
# Put key into SERVICE_ACCT_KEY_FILE
docker run --rm -e VAULT_TOKEN=${VAULT_TOKEN} -e VAULT_ADDR=${VAULT_ADDR} broadinstitute/dsde-toolbox vault read --format=json ${DEPLOY_KEY_PATH} | jq .data > ${SERVICE_ACCT_KEY_FILE}

CODEBASE_PATH=/workbench-tos

# Process all Consul .ctmpl files
# Vault token is required by the docker image regardless of whether you have any data in Vault or not
docker run --rm -v $PWD:${CODEBASE_PATH} \
  -e INPUT_PATH=${CODEBASE_PATH}/function \
  -e OUT_PATH=${CODEBASE_PATH}/function \
  -e ENVIRONMENT=${ENVIRONMENT} \
  -e VAULT_TOKEN=${VAULT_TOKEN} \
  -e CONSUL_CONFIG=${CODEBASE_PATH}/vault-config.json \
  broadinstitute/dsde-toolbox:dev render-templates.sh

# Use google/cloud-sdk image to deploy the cloud function
# TODO: is there a smaller version of this image we can use?
docker run --rm -v $PWD:${CODEBASE_PATH} \
    -e BASE_URL="https://us-central1-${PROJECT_NAME}.cloudfunctions.net" \
    google/cloud-sdk:220.0.0 /bin/bash -c \
    "gcloud config set project ${PROJECT_NAME} &&
     gcloud auth activate-service-account --key-file ${CODEBASE_PATH}/${SERVICE_ACCT_KEY_FILE} &&
     cd ${CODEBASE_PATH} &&
     gcloud functions deploy tos --source=./function --trigger-http --runtime nodejs6"
