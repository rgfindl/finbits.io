#!/bin/bash

PROFILE="--profile bluefin"

case $1 in
    ui)
        aws cloudformation deploy \
        --template-file ui.template.yml \
        --stack-name finbits-ui \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides \
        TLD='finbits.io' \
        Domain='finbits.io' \
        SSLArn='arn:aws:acm:us-east-1:132093761664:certificate/1a4bc1e2-66b0-4d4d-9961-e182e6880c45' \
        ${PROFILE}
        ;;
    *)
        echo $"Usage: $0 {ui}"
        exit 1
esac