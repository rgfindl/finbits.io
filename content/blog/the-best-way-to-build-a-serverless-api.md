---
title: "The Best Way to Build a Serverless Api"
date: 2019-09-05T08:15:17-04:00
draft: true
image: "/images/blog/electron-react.jpg"
tags: ["software"]
type: "post"
comments: true
---

# Prerequisites   
Make sure you have installed [node & npm](https://nodejs.org).

Install [AWS SAM](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/serverless-sam-cli-install.html).  Also, aws account, iam user, aws-cli, docker, and finally sam.

# Setup
```
npm init
```

`package.json` will look like this.
```
{
  "name": "the-best-serverless-api",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "test": "echo \"Error: no test specified\" && exit 1"
  },
  "repository": {
    "type": "git",
    "url": "git+https://github.com/rgfindl/the-best-serverless-api.git"
  },
  "author": "",
  "license": "ISC",
  "bugs": {
    "url": "https://github.com/rgfindl/the-best-serverless-api/issues"
  },
  "homepage": "https://github.com/rgfindl/the-best-serverless-api#readme"
}
```

I also add a `.gitignore` like this:
```
node_modules
```

# Register endpoint
`src/public/register.js`
```

const HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Credentials': 'true',
  'Access-Control-Allow-Methods': 'GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS',
  'Access-Control-Allow-Headers': 'X-Requested-With, Accept, Origin, Authorization, Content-Type, Referer, User-Agent',
  'Access-Control-Expose-Headers': 'Content-Length, Content-Range, Authorization',
  'Cache-Control': 'max-age=0'
};

exports.handler = async (event, context, callback) => {
  console.log(JSON.stringify(event, null, 3));
  if (_.isEqual(event.httpMethod, 'OPTIONS')) {
    return callback(null, {
      statusCode: 200,
      headers: HEADERS
    });
  }
  return callback(null, {
    statusCode: 200,
    headers: HEADERS,
    body: JSON.stringify(event, null, 3)
  });
};
```

# AWS SAM Template
`api.template.yml`


# Deps

** Switch to yarn

```
yarn add --dev aws-sdk
yarn add --dev eslint@^5.16.0
yarn add --dev eslint-config-airbnb-base
yarn add --dev eslint-plugin-import
```

```
yarn add jsonwebtoken
```

# Linter

```
./node_modules/.bin/eslint --init
```


```
{
  "name": "the-best-serverless-api",
  "version": "1.0.0",
  "description": "",
  "main": "index.js",
  "scripts": {
    "start": "sh ./start-sam-local.sh",
    "test": "echo \"Error: no test specified\" && exit 1",
    "deploy": "sh ./stack-up.sh api"
  },
  "repository": {
    "type": "git",
    "url": "git+https://github.com/rgfindl/the-best-serverless-api.git"
  },
  "author": "",
  "license": "ISC",
  "bugs": {
    "url": "https://github.com/rgfindl/the-best-serverless-api/issues"
  },
  "homepage": "https://github.com/rgfindl/the-best-serverless-api#readme",
  "dependencies": {
    "jsonwebtoken": "^8.5.1"
  },
  "devDependencies": {
    "aws-sdk": "^2.524.0",
    "eslint": "^4.19.1",
    "eslint-config-airbnb-base": "^12.1.0",
    "eslint-plugin-import": "^2.11.0"
  },
  "eslintConfig": {
    "extends": "airbnb-base",
    "env": {
      "es6": true,
      "browser": true
    },
    "rules": {
      "camelcase": [
        "warn"
      ],
      "max-len": [
        "warn"
      ],
      "no-underscore-dangle": [
        "warn"
      ],
      "no-console": [
        "off"
      ],
      "brace-style": [
        "off"
      ],
      "comma-dangle": [
        "error",
        "never"
      ],
      "no-unused-vars": [
        "warn"
      ],
      "no-var": [
        "off"
      ],
      "one-var": [
        "off"
      ],
      "import/no-extraneous-dependencies": [
        "off"
      ]
    }
  }
}
```

