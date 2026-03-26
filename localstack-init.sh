#!/bin/bash
set -e

# Cria fila do evaluation service
awslocal sqs create-queue --queue-name evaluation-events

# Cria fila do analytics service
awslocal sqs create-queue --queue-name analytics-queue

# Cria tabela DynamoDB usada pelo analytics service
awslocal dynamodb create-table \
    --table-name ToggleMasterAnalytics \
    --attribute-definitions AttributeName=event_id,AttributeType=S \
    --key-schema AttributeName=event_id,KeyType=HASH \
    --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1
