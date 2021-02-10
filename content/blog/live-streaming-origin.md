---
title: "Live Streaming Origin"
date: 2020-06-12T06:15:16-04:00
draft: false
image: "/images/blog/live-streaming-origin.jpg"
tags: ["software"]
type: "post"
comments: true
---

If you're just joining us, please take a look at part 1 in this 3-part series.

- Part 1 - [Server](/blog/live-streaming-server)
- Part 2 - [Proxy](/blog/live-streaming-proxy)
- Part 3 - Origin

This blog post is about the Origin.  Remember we have 3 services in this architecture.  Proxy -> Server <- Origin

How do we route & cache HTTP traffic to a fleet of RTMP Servers to serve the HLS files?

We need a single endpoint like `live.finbits.io`.

A user will play the the video using a URL like `live.finbits.io/<stream key>/live.m3u8`.

HTTP is __stateless__ so we can use an AWS ALB load balancer.  Yay!

We also use AWS CloudFront as the CDN.  It looks like this.

Route 53 -> CloudFront -> ALB -> Origin(s) -> Server(s).

But how does the Origin know which Server to fetch the HLS files from?

We use a Redis cache to store the mapping between "stream key" and Server "IP:PORT".  

Our Origin is simply NGINX with a small backed that performs the Redis cache lookup.

Let's take a look at our NGINX config.

```
worker_processes  auto;

error_log /dev/stdout info;

events {
  worker_connections  1024;
}

http {
  include       /etc/nginx/mime.types;
  default_type  application/octet-stream;

  log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

  access_log /dev/stdout main;

  sendfile        on;

  keepalive_timeout  65;

  gzip on;

  proxy_cache_path /tmp/cache/ levels=1:2 keys_zone=CONTENTCACHE:10m max_size=15g inactive=10m use_temp_path=off;

  ignore_invalid_headers off;

  upstream node-backend {
    server localhost:3000 max_fails=0;
  }

  <% servers.forEach(function(server, index) { %>
  upstream media<%= index %>-backend {
    server <%= server %> max_fails=0;
  }
  <% }); %>

  server {
    listen 80;
    server_name localhost;
    sendfile off;

    <% servers.forEach(function(server, index) { %>
    location ~ ^/<%= server %>/(.*)$ {
      internal;
      proxy_pass http://media<%= index %>-backend/$1$is_args$args;
    }
    <% }); %>

    location ~ ^/(.*live\.m3u8)$ {
      #
      # Cache results on local disc
      #
      proxy_cache CONTENTCACHE;
      proxy_cache_lock on;
      proxy_cache_key $scheme$proxy_host$uri;
      proxy_cache_valid 1m;
      proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;

      #
      # CORS
      #
      include /etc/nginx/nginx.cors.conf;

      #
      # Proxy Pass
      #
      proxy_pass http://node-backend/$1$is_args$args;
    }

    location ~ ^/(.*index\.m3u8)$ {
      #
      # Cache results on local disc
      #
      proxy_cache CONTENTCACHE;
      proxy_cache_lock on;
      proxy_cache_key $scheme$proxy_host$uri;
      proxy_cache_valid 1s;
      proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;

      #
      # CORS
      #
      include /etc/nginx/nginx.cors.conf;

      #
      # Proxy Pass
      #
      proxy_pass http://node-backend/$1$is_args$args;
    }

    location ~ ^/(.*\.ts)$ {
      #
      # Cache results on local disc
      #
      proxy_cache CONTENTCACHE;
      proxy_cache_lock on;
      proxy_cache_key $scheme$proxy_host$uri;
      proxy_cache_valid 60s;
      proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;

      #
      # CORS
      #
      include /etc/nginx/nginx.cors.conf;

      #
      # Proxy Pass
      #
      proxy_pass http://node-backend/$1$is_args$args;
    }

    location /healthcheck {
      proxy_pass http://node-backend/healthcheck$is_args$args;
    }

    location /nginx_status {
      stub_status on;

      access_log off;
      allow 127.0.0.1;
      deny all;
    }
  }
}
```

When a request comes in, like `live.finbits.io/<stream key>/live.m3u8`, it first hits the `node-backend`.

The `node-backend` performs the Redis cache lookup, to get the Server IP:PORT, then responds with an internal NGINX redirect to the corresponding `media-backend`.

The `media-backend` performs a proxy_pass to the Server to fetch the HLS.

What about caching?  

The cache headers are added by the Server. 

The Origin has an internal NGINX cache.  The goal is to reduce the load on the Servers as much as possible.  

We use the following NGINX cache control to prevent a thundering herd run on the Server. `proxy_cache_lock on;`  If we get many simultaneous requests before NGINX has the cache, NGINX will block all requests but 1 until the cache is populated.  This keeps our Servers safe.

We finally propagate our cache headers all they way back to the CloudFront CDN which is our primary cache point.  

What about CORS headers?

We set the following CORS headers on every request.

```
if ($request_method = 'OPTIONS') {
    add_header 'Access-Control-Allow-Origin' '*';
    add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS';
    #
    # Custom headers and headers various browsers *should* be OK with but aren't
    #
    add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    #
    # Tell client that this pre-flight info is valid for 20 days
    #
    add_header 'Access-Control-Max-Age' 1728000;
    add_header 'Content-Type' 'text/plain; charset=utf-8';
    add_header 'Content-Length' 0;
    return 204;
}
if ($request_method = 'POST') {
    add_header 'Access-Control-Allow-Origin' '*';
    add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS';
    add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
}
if ($request_method = 'GET') {
    add_header 'Access-Control-Allow-Origin' '*';
    add_header 'Access-Control-Allow-Methods' 'GET, OPTIONS';
    add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range';
    add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range';
}
```

Same as the Proxy we have to keep the fleet of Servers in-sync.

When the service starts we fetch the list of Servers (IP:PORT) and add them to the NGINX configuration.  Now we're ready to route traffic.

We then run a cron job to perform this action again, to pick up any new Servers.  NGINX is reloaded with zero downtime.

## Service

Now it's time to deploy our Origin.

The Origin service has 2 stacks:

- [ecr](https://github.com/rgfindl/live-streaming-server/blob/master/origin/stacks/ecr.stack.yml) - Docker image registry
- [service](https://github.com/rgfindl/live-streaming-server/blob/master/origin/stacks/service.stack.yml) - Fargate service

First create the docker ECR registry.

```
sh ./stack-up.sh ecr
```

Now we can build, tag, and push the Docker image to the registry.  

First update the [package.json](https://github.com/rgfindl/live-streaming-server/blob/master/origin/package.json#L9-L13) scripts to include your AWS account id.

To build, tag, and push the Docker image to the registry, run the following command.

```
yarn run deploy <version>
```

Now we can deploy the service stack which will deploy our new image to Fargate.

First update the `Version` [here](https://github.com/rgfindl/live-streaming-server/blob/master/origin/stacks/stack-up.sh#L21).

Then run:

```
sh ./stack-up.sh service
```

Your Origin should now be running in your ECS cluster as a Fargate task.  

In conclusion... I think this architecture and implementation works pretty well.  It hasn't been battle tested.  Here are some things I'd still like to do and some areas for improvement.

1.) Test with more clients & videos.

I tested with VLC, FFMPEG, and my phone.  I pushed live video, screen recordings, and VOD's in a loop.  It always worked... but it would be good to test with many different clients before going to production.

2.) Load testing.

It would be a good idea to see how this architecture does under load.

RTMP load testing?  The limiting factor is the number of Servers.  We can only push one stream per server.  Not much to test here.  Just need to make sure that one Server can handle a large video stream.

HTTP load testing?  This could be done pretty easily using something like `wkr`.

3.) Auto scaling.

This is the big one.  If we were to offer a service like Twitch, how would we scale up the number of Servers to meet the growing number of streamers?  How would we scale down to save costs and not terminate a users stream.  

I think we'd need a custom Controller to perform the scaling and communication between all the services to update their configurations realtime instead of every minute via cron.

That's it.  I hope you enjoyed learning about RTMP-to-HLS streaming.