---
title: "Live Streaming Server"
date: 2020-06-07T06:34:20-04:00
draft: false
image: "/images/blog/live-streaming-server.jpg"
tags: ["software"]
type: "post"
comments: true
---
I decided to build a live streaming server that accepts RTMP input and outputs Adaptive Bitrate (ABR) HLS.

[https://github.com/rgfindl/live-streaming-server](https://github.com/rgfindl/live-streaming-server)

I wanted users to be able to stream anytime using their private stream key.  Much like how Twitch, Facebook, and YouTube do it.

I also wanted the live stream recorded and I wanted the user to be able to relay their live stream to other destinations like Twitch, Facebook, and YouTube.

The final architecture is actually 3 services: Proxy -> Server <- Origin

I will cover the Proxy and the Origin in posts [2](/blog/live-streaming-proxy) and [3](/blog/live-streaming-origin) in this blog post series.

Take a look at the architecture:
![](/images/blog/live-streaming-server-full.jpg "Architecture")


All 3 services are running as Docker containers on AWS Fargate.

RTMP is sent to the Proxy at `rtmp.finbits.io`.

HLS is served by the Origin at `live.finbits.io`.

The Redis cache stores the stream key to Server mapping so the Origin knows which Server to fetch the HLS from.  We could have many Servers to meet demand.

S3 is used to store the recordings.  The recordings are single bitrate HLS.  The largest bitrate from the ABR.live

All 3 services scale independently to meet demand.  The Server would scale the most.  Transcoding RTMP into ABR HLS is very CPU intensive.

## Node Media Server

For the RTMP Server I decided to use a fork of [Node Media Server](https://github.com/illuspas/Node-Media-Server).

https://github.com/rgfindl/Node-Media-Server

Node Media Server accepts RTMP on port 1935.  FFMPEG is then used to transcode the RTMP input into HLS.  FFMPEG is also used to relay to social media destinations.

Why Node Media Server?

It is actively maintained, it has a lot of github stars, and I like node.js.  

I first tried [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module), because nginx is great.  But I couldn't get the social relay working the way I wanted.  Also, this project is no longer maintained and is pretty old.

I also looked at [ossrs/srs](https://github.com/ossrs/srs), which seems to be based on nginx-rtmp-module.  It didn't seem as flexible, maybe because I'm not a c/c++ developer.

Why fork Node Media Server?  What did I change?

I added a few more options to the Node Media Server `config` to get the HLS working.  Specifically the `config.trans.tasks` object.

```
const config = {
  ...
  trans: {
    tasks: [
      raw: [...], # FFMPEG command
      ouPaths: [...], # HLS output paths
      cleanup: false, # Don't delete the ouPaths, we'll do it later
    ]
  }
}
```

I'll talk about each of these in more details below.

## FFMPEG

FFMPEG is used to transcode the rtmp input into 3 HLS outputs.
 
 - 640 x 360
 - 842 x 480
 - 720 x 1280

```
ffmpeg -hide_banner -y -fflags nobuffer -i rtmp://127.0.0.1:1935/stream/test \
  -vf scale=w=640:h=360:force_original_aspect_ratio=decrease -c:a aac -ar 48000 -c:v libx264 -preset veryfast -profile:v main -crf 20 -sc_threshold 0 -g 48 -keyint_min 48 -hls_time 4 -hls_list_size 6 -hls_flags delete_segments -max_muxing_queue_size 1024 -start_number 100 -b:v 800k -maxrate 856k -bufsize 1200k -b:a 96k -hls_segment_filename media/test/360p/%03d.ts media/test/360p.m3u8 \
  -vf scale=w=842:h=480:force_original_aspect_ratio=decrease -c:a aac -ar 48000 -c:v libx264 -preset veryfast -profile:v main -crf 20 -sc_threshold 0 -g 48 -keyint_min 48 -hls_time 4 -hls_list_size 6 -hls_flags delete_segments -max_muxing_queue_size 1024 -start_number 100 -b:v 1400k -maxrate 1498k -bufsize 2100k -b:a 128k -hls_segment_filename media/test/480p/%03d.ts media/test/480p.m3u8 \
  -vf scale=w=1280:h=720:force_original_aspect_ratio=decrease -c:a aac -ar 48000 -c:v libx264 -preset veryfast -profile:v main -crf 20 -sc_threshold 0 -g 48 -keyint_min 48 -hls_time 4 -hls_list_size 6 -hls_flags delete_segments -max_muxing_queue_size 1024 -start_number 100 -b:v 2800k -maxrate 2996k -bufsize 4200k -b:a 128k -hls_segment_filename media/test/720p/%03d.ts media/test/720p.m3u8

```

What about the ABR playlist file? 

We create that once the first HLS playlist file is created.  It looks like this:

```
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
360p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=842x480
480p/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
720p/index.m3u8
```

## Server

Our Server does the following things:

- Takes RTMP input and converts it to HLS
- Creates an ABR HLS playlist
- Copies the highest bitrate HLS to S3
- Relay's RTMP to social destinations based on query parameters
- Exposes a hook for stream key validation
- Serves HLS via NGINX reverse proxy with cache headers and CORS

### app.js

The [app.js](https://github.com/rgfindl/live-streaming-server/blob/master/server/app.js) does most of the work.  Let's take a look at that file in it's entirety.

```
const NodeMediaServer = require('node-media-server');
const _ = require('lodash');
const { join } = require('path');
const querystring = require('querystring');
const fs = require('./lib/fs');
const hls = require('./lib/hls');
const abr = require('./lib/abr');
const ecs = require('./lib/ecs');
const cache = require('./lib/cache');
const logger = require('./lib/logger');
const utils = require('./lib/utils');

const LOG_TYPE = 4;
logger.setLogType(LOG_TYPE);

// init RTMP server
const init = async () => {
  try {
    // Fetch the container server address (IP:PORT)
    // The IP is from the EC2 server.  The PORT is from the container.
    const SERVER_ADDRESS = process.env.NODE_ENV === 'production' ? await ecs.getServer() : '';

    // Set the Node-Media-Server config.
    const config = {
      logType: LOG_TYPE,
      rtmp: {
        port: 1935,
        chunk_size: 60000,
        gop_cache: true,
        ping: 30,
        ping_timeout: 60
      },
      http: {
        port: 8080,
        mediaroot: process.env.MEDIA_ROOT || 'media',
        allow_origin: '*',
        api: true
      },
      auth: {
        api: false
      },
      relay: {
        ffmpeg: process.env.FFMPEG_PATH || '/usr/local/bin/ffmpeg',
        tasks: [
          {
            app: 'stream',
            mode: 'push',
            edge: 'rtmp://127.0.0.1/hls',
          },
        ],
      },
      trans: {
        ffmpeg: process.env.FFMPEG_PATH || '/usr/local/bin/ffmpeg',
        tasks: [
          {
            app: 'hls',
            hls: true,
            raw: [
              '-vf',
              'scale=w=640:h=360:force_original_aspect_ratio=decrease',
              '-c:a',
              'aac',
              '-ar',
              '48000',
              '-c:v',
              'libx264',
              '-preset',
              'veryfast',
              '-profile:v',
              'main',
              '-crf',
              '20',
              '-sc_threshold',
              '0',
              '-g',
              '48',
              '-keyint_min',
              '48',
              '-hls_time',
              '6',
              '-hls_list_size',
              '10',
              '-hls_flags',
              'delete_segments',
              '-max_muxing_queue_size',
              '1024',
              '-start_number',
              '${timeInMilliseconds}',
              '-b:v',
              '800k',
              '-maxrate',
              '856k',
              '-bufsize',
              '1200k',
              '-b:a',
              '96k',
              '-hls_segment_filename',
              '${mediaroot}/${streamName}/360p/%03d.ts',
              '${mediaroot}/${streamName}/360p/index.m3u8',
              '-vf',
              'scale=w=842:h=480:force_original_aspect_ratio=decrease',
              '-c:a',
              'aac',
              '-ar',
              '48000',
              '-c:v',
              'libx264',
              '-preset',
              'veryfast',
              '-profile:v',
              'main',
              '-crf',
              '20',
              '-sc_threshold',
              '0',
              '-g',
              '48',
              '-keyint_min',
              '48',
              '-hls_time',
              '6',
              '-hls_list_size',
              '10',
              '-hls_flags',
              'delete_segments',
              '-max_muxing_queue_size',
              '1024',
              '-start_number',
              '${timeInMilliseconds}',
              '-b:v',
              '1400k',
              '-maxrate',
              '1498k',
              '-bufsize',
              '2100k',
              '-b:a',
              '128k',
              '-hls_segment_filename',
              '${mediaroot}/${streamName}/480p/%03d.ts',
              '${mediaroot}/${streamName}/480p/index.m3u8',
              '-vf',
              'scale=w=1280:h=720:force_original_aspect_ratio=decrease',
              '-c:a',
              'aac',
              '-ar',
              '48000',
              '-c:v',
              'libx264',
              '-preset',
              'veryfast',
              '-profile:v',
              'main',
              '-crf',
              '20',
              '-sc_threshold',
              '0',
              '-g',
              '48',
              '-keyint_min',
              '48',
              '-hls_time',
              '6',
              '-hls_list_size',
              '10',
              '-hls_flags',
              'delete_segments',
              '-max_muxing_queue_size',
              '1024',
              '-start_number',
              '${timeInMilliseconds}',
              '-b:v',
              '2800k',
              '-maxrate',
              '2996k',
              '-bufsize',
              '4200k',
              '-b:a',
              '128k',
              '-hls_segment_filename',
              '${mediaroot}/${streamName}/720p/%03d.ts',
              '${mediaroot}/${streamName}/720p/index.m3u8'
            ],
            ouPaths: [
              '${mediaroot}/${streamName}/360p',
              '${mediaroot}/${streamName}/480p',
              '${mediaroot}/${streamName}/720p'
            ],
            hlsFlags: '',
            cleanup: false,
          },
        ]
      },
    };

    // Construct the NodeMediaServer
    const nms = new NodeMediaServer(config);

    // Create the maps we'll need to track the current streams.
    this.dynamicSessions = new Map();
    this.streams = new Map();

    // Start the VOD S3 file watcher and sync.
    hls.recordHls(config, this.streams);

    //
    // HLS callbacks
    //
    hls.on('newHlsStream', async (name) => {
      // Create the ABR HLS playlist file.
      await abr.createPlaylist(config.http.mediaroot, name);
      // Send the "stream key" <-> "IP:PORT" mapping to Redis
      // This tells the Origin which Server has the HLS files
      await cache.set(name, SERVER_ADDRESS);
    });

    //
    // RTMP callbacks
    //
    nms.on('preConnect', (id, args) => {
      logger.log('[NodeEvent on preConnect]', `id=${id} args=${JSON.stringify(args)}`);
      // Pre connect authorization
      // let session = nms.getSession(id);
      // session.reject();
    });
    
    nms.on('postConnect', (id, args) => {
      logger.log('[NodeEvent on postConnect]', `id=${id} args=${JSON.stringify(args)}`);
    });
    
    nms.on('doneConnect', (id, args) => {
      logger.log('[NodeEvent on doneConnect]', `id=${id} args=${JSON.stringify(args)}`);
    });
    
    nms.on('prePublish', (id, StreamPath, args) => {
      logger.log('[NodeEvent on prePublish]', `id=${id} StreamPath=${StreamPath} args=${JSON.stringify(args)}`);
      // Pre publish authorization
      // let session = nms.getSession(id);
      // session.reject();
    });
    
    nms.on('postPublish', async (id, StreamPath, args) => {
      logger.log('[NodeEvent on postPublish]', `id=${id} StreamPath=${StreamPath} args=${JSON.stringify(args)}`);
      if (StreamPath.indexOf('/hls/') != -1) {
        // Set the "stream key" <-> "id" mapping for this RTMP/HLS session
        // We use this when creating the DVR HLS playlist name on S3.
        const name = StreamPath.split('/').pop();
        this.streams.set(name, id);
      } else if (StreamPath.indexOf('/stream/') != -1) {
        //
        // Start Relay to youtube, facebook, and/or twitch
        //
        if (args.youtube) {
          const params = utils.getParams(args, 'youtube_');
          const query = _.isEmpty(params) ? '' : `?${querystring.stringify(params)}`;
          const url = `rtmp://a.rtmp.youtube.com/live2/${args.youtube}${query}`;
          const session = nms.nodeRelaySession({
            ffmpeg: config.relay.ffmpeg,
            inPath: `rtmp://127.0.0.1:${config.rtmp.port}${StreamPath}`,
            ouPath: url
          });
          session.id = `youtube-${id}`;
          session.on('end', (id) => {
            this.dynamicSessions.delete(id);
          });
          this.dynamicSessions.set(session.id, session);
          session.run();
        }
        if (args.facebook) {
          const params = utils.getParams(args, 'facebook_');
          const query = _.isEmpty(params) ? '' : `?${querystring.stringify(params)}`;
          const url = `rtmps://live-api-s.facebook.com:443/rtmp/${args.facebook}${query}`;
          session = nms.nodeRelaySession({
            ffmpeg: config.relay.ffmpeg,
            inPath: `rtmp://127.0.0.1:${config.rtmp.port}${StreamPath}`,
            ouPath: url
          });
          session.id = `facebook-${id}`;
          session.on('end', (id) => {
            this.dynamicSessions.delete(id);
          });
          this.dynamicSessions.set(session.id, session);
          session.run();
        }
        if (args.twitch) {
          const params = utils.getParams(args, 'twitch_');
          const query = _.isEmpty(params) ? '' : `?${querystring.stringify(params)}`;
          const url = `rtmp://live-jfk.twitch.tv/app/${args.twitch}${query}`;
          session = nms.nodeRelaySession({
            ffmpeg: config.relay.ffmpeg,
            inPath: `rtmp://127.0.0.1:${config.rtmp.port}${StreamPath}`,
            ouPath: url,
            raw: [
              '-c:v',
              'libx264',
              '-preset',
              'veryfast',
              '-c:a',
              'copy',
              '-b:v',
              '3500k',
              '-maxrate',
              '3750k',
              '-bufsize',
              '4200k',
              '-s',
              '1280x720',
              '-r',
              '30',
              '-f',
              'flv',
              '-max_muxing_queue_size',
              '1024',
            ]
          });
          session.id = `twitch-${id}`;
          session.on('end', (id) => {
            this.dynamicSessions.delete(id);
          });
          this.dynamicSessions.set(session.id, session);
          session.run();
        }
      }
    });
    
    nms.on('donePublish', async (id, StreamPath, args) => {
      logger.log('[NodeEvent on donePublish]', `id=${id} StreamPath=${StreamPath} args=${JSON.stringify(args)}`);
      if (StreamPath.indexOf('/hls/') != -1) {
        const name = StreamPath.split('/').pop();
        // Delete the Redis cache key for this stream
        await cache.del(name);
        // Wait a few minutes before deleting the HLS files on this Server
        // for this session
        const timeoutMs = _.isEqual(process.env.NODE_ENV, 'development') ?
          1000 : 
          2 * 60 * 1000;
        await utils.timeout(timeoutMs);
        try {
          // Cleanup directory
          logger.log('[Delete HLS Directory]', `dir=${join(config.http.mediaroot, name)}`);
          this.streams.delete(name);
          fs.rmdirSync(join(config.http.mediaroot, name));
        } catch (err) {
          logger.error(err);
        }
      } else if (StreamPath.indexOf('/stream/') != -1) {
        //
        // Stop the Relay's
        //
        if (args.youtube) {
          let session = this.dynamicSessions.get(`youtube-${id}`);
          if (session) {
            session.end();
            this.dynamicSessions.delete(`youtube-${id}`);
          }
        }
        if (args.facebook) {
          let session = this.dynamicSessions.get(`facebook-${id}`);
          if (session) {
            session.end();
            this.dynamicSessions.delete(`facebook-${id}`);
          }
        }
        if (args.twitch) {
          let session = this.dynamicSessions.get(`twitch-${id}`);
          if (session) {
            session.end();
            this.dynamicSessions.delete(`twitch-${id}`);
          }
        }
      }
    });
    
    nms.on('prePlay', (id, StreamPath, args) => {
      logger.log('[NodeEvent on prePlay]', `id=${id} StreamPath=${StreamPath} args=${JSON.stringify(args)}`);
      // Pre play authorization
      // let session = nms.getSession(id);
      // session.reject();
    });
    
    nms.on('postPlay', (id, StreamPath, args) => {
      logger.log('[NodeEvent on postPlay]', `id=${id} StreamPath=${StreamPath} args=${JSON.stringify(args)}`);
    });
    
    nms.on('donePlay', (id, StreamPath, args) => {
      logger.log('[NodeEvent on donePlay]', `id=${id} StreamPath=${StreamPath} args=${JSON.stringify(args)}`);
    });

    // Run the NodeMediaServer
    nms.run();
  } catch (err) {
    logger.log('Can\'t start app', err);
    process.exit();
  }
};
init();
```

### Url Structure

When calling the Application your URL would look something like this.

The social query params are optional.  When present they Relay to the corresponding social destination.

```
rtmp://rtmp.finbits.io:1935/stream/testkeyd?twitch=<your twitch key>&youtube=<your youtube key>&facebook=<your facebook key>&facebook_s_bl=<your facebook bl>&facebook_s_sc=<your facebook s_sc>&facebook_s_sw=<your facebook sw>&facebook_s_vt=<your facebook vt>&facebook_a=<your facebook a>
```

### DVR

The highest bitrate HLS is copied to S3.

The bucket path looks like this:

`<bucket>/<stream key>/vod-<stream id>.m3u8`

```
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:6
#EXT-X-MEDIA-SEQUENCE:1590665387025
#EXTINF:6.000000,
720p/1590665387025.ts
#EXTINF:6.000000,
720p/1590665387026.ts
#EXT-X-ENDLIST
```

### Stream Key Validation

You can perform stream key validation on either the `preConnect` or `prePublish` RTMP events.  Here is an example:

```
nms.on('preConnect', (id, args) => {
  logger.log('[NodeEvent on preConnect]', `id=${id} args=${JSON.stringify(args)}`);
  // Pre connect authorization
  if (isInvalid) {
    let session = nms.getSession(id);
    session.reject();
  }
});
```

### NGINX

We use NGINX as a reverse proxy to serve the static HLS files.  It has better performance that express.js.  

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

  ignore_invalid_headers off;

  upstream node-backend {
    server localhost:8080 max_fails=0;
  }

  server {
    listen 8000;
    server_name localhost;
    sendfile off;

    location ~ live\.m3u8 {
      add_header Cache-Control "max-age=60";
      root /usr/src/app/media;
    }

    location ~ index\.m3u8 {
      add_header Cache-Control "no-cache";
      root /usr/src/app/media;
    }

    location ~ \.ts {
      add_header Cache-Control "max-age=600";
      root /usr/src/app/media;
    }

    location /nginx_status {
      stub_status on;

      access_log off;
      allow 127.0.0.1;
      deny all;
    }

    location / {
      add_header Cache-Control "no-cache";
      proxy_pass http://node-backend/;
    }
  }
}
```

As you can see we don't cache the HLS playlist files.  We do cache the ABR file and the *.ts media files.

## Infrastructure

This entire application runs on AWS.  Before we can spin up the Proxy, Server, and Origin Fargate services we have to create some shared infrastructure.  Here is a list of the shared infrastructure:

- [assets](https://github.com/rgfindl/live-streaming-server/blob/master/stacks/assets.stack.yml) - S3 Bucket
- [vpc](https://github.com/rgfindl/live-streaming-server/blob/master/stacks/vpc.stack.yml) - VPC for our Fargate services
- [ecs](https://github.com/rgfindl/live-streaming-server/blob/master/stacks/ecs.stack.yml) - ECS cluster for our Fargate services
- [security](https://github.com/rgfindl/live-streaming-server/blob/master/stacks/security.stack.yml) - Security Group's for our Fargate services
- [redis](https://github.com/rgfindl/live-streaming-server/blob/master/stacks/redis.stack.yml) - A Redis cache to store the "stream key" to "IP:PORT" mapping
- [proxy dns](https://github.com/rgfindl/live-streaming-server/blob/master/stacks/proxy-dns.stack.yml) - rtmp.finbits.io DNS

You can use the [stack-up.sh](https://github.com/rgfindl/live-streaming-server/blob/master/stacks/stack-up.sh) script to deploy each of these stacks to your AWS account.  You'll have to change the `PROFILE="--profile bluefin"` to match your credentials file.

Here is an example:

```
sh ./stack-up.sh vpc
```

## Service

Now that we have the shared infrastructure up.  Let's get the Server deployed.

The Server service has 2 stacks:

- [ecr](https://github.com/rgfindl/live-streaming-server/blob/master/server/stacks/ecr.stack.yml) - Docker image registry
- [service](https://github.com/rgfindl/live-streaming-server/blob/master/server/stacks/service.stack.yml) - Fargate service

First create the docker ECR registry.

```
sh ./stack-up.sh ecr
```

Now we can build, tag, and push the Docker image to the registry.  

First update the [package.json](https://github.com/rgfindl/live-streaming-server/blob/master/server/package.json#L9-L13) scripts to include your AWS account id.

To build, tag, and push the Docker image to the registry, run the following command.

```
yarn run deploy <version>
```

Now we can deploy the service stack which will deploy our new image to Fargate.

First update the `Version` [here](https://github.com/rgfindl/live-streaming-server/blob/master/server/stacks/stack-up.sh#L21).

Then run:

```
sh ./stack-up.sh service
```

Your Server should now be running in your ECS cluster as a Fargate task.  

But... you can't access it directly.  :( 
  
We need a [Proxy](/blog/live-streaming-proxy) to route RTMP traffic to our fleet of Servers to publish RTMP.  

We also need an [Origin](/blog/live-streaming-origin) to route HTTP traffic to our fleet of Servers.

Take a look at the next blog post in this 3-part series:

- Part 1 - Server
- Part 2 - [Proxy](/blog/live-streaming-proxy)
- Part 3 - [Origin](/blog/live-streaming-origin)