#!/bin/bash

hugo && aws s3 sync public/ s3://finbits.io --acl public-read --profile=bluefin --delete --cache-control max-age=1