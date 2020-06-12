---
title: "Live Streaming Proxy"
date: 2020-06-12T06:15:09-04:00
draft: false
image: "/images/blog/live-streaming-proxy.jpg"
tags: ["software"]
type: "post"
comments: true
---

If you're just joining us, please take a look at part 1 in this 3-part series.

- Part 1 - [Server](/blog/live-streaming-server)
- Part 2 - Proxy
- Part 3 - [Origin](/blog/live-streaming-origin)

This blog post is about the Proxy.  Remember we have 3 services in this architecture.  Proxy -> Server <- Origin

How do we route __stateful__ RTMP traffic to a fleet of RTMP Servers?

We need a single endpoint like `rtmp.finbits.io`.

A user will push RTMP using a URL like `rtmp.finbits.io/stream/<stream key>`

RTMP is stateful which makes load balancing and scaling much more challenging.  

If this were a stateless application we'd use AWS ALB with an Auto Scaling Group.

Can we use AWS ALB?  Nope, ALB doesn't support RTMP.

An Auto Scaling Group might work but scaling down will be a challenge.  You wouldn't want to terminate a Server that a user is actively streaming to.

Why not just redirect RTMP directly to the Servers?  This would be great but RTMP redirects are fairly new and not all clients support it.

So, how do we route __stateful__ RTMP traffic to a fleet of RTMP Servers?

We can use HAProxy and weighted Route53 DNS routing.  We could have n number of Origin (HAProxy) services running, all with public IPs, and them route traffic to all instances via Route53 weighted record sets.

The only gotcha with this service is making sure it picks up any new Servers that are added to handle load.

When the service starts we fetch the list of Servers (IP:PORT) and add them to the HAProxy configuration.  Now we're ready to route traffic.

We then run a cron job to perform this action again, to pick up any new Servers.  HAProxy is reloaded with zero downtime.

Let's take a look at the HAProxy config.

```
global
 pidfile /var/run/haproxy.pid
 maxconn <%= servers.length %>

defaults
 log global
 timeout connect 10s
 timeout client 30s
 timeout server 30s

frontend ft_rtpm
 bind *:1935 name rtmp
 mode tcp
 maxconn <%= servers.length %>
 default_backend bk_rtmp

frontend ft_http
 bind *:8000 name http
 mode http
 maxconn 600
 default_backend bk_http

backend bk_http
 mode http
 errorfile 503 /usr/local/etc/haproxy/healthcheck.http

backend bk_rtmp 
 mode tcp
 balance roundrobin
 <% servers.forEach(function(server, index) { %>
 server media<%= index %> <%= server %> check maxconn 1 weight 10
 <% }); %>
```

As you can see we're using EJS template engine to generate the config.

__global__
```
global
 pidfile /var/run/haproxy.pid
 maxconn <%= servers.length %>
```
We store the pidfile, so we can use it to restart the service when our cron job runs to update the Servers list.

'maxconn' is set to the number of Servers.  In our design each Server can only accept 1 connection.  FFMPEG draws a lot of CPU and we're using Fargate with lower CPU tasks.  

You could use EC2's instead of Fargate with highly performant instance types.  Then you could handle more connections per Server.

It might be cool to also use NVIDIA hardware acceleration with FFMPEG, but I didn't get that far.  It was getting kinda complicated with Docker.

__frontend__
```
frontend ft_rtpm
 bind *:1935 name rtmp
 mode tcp
 maxconn <%= servers.length %>
 default_backend bk_rtmp
```
Here we declare the RTMP frontend on port 1935.  It leverages the RTMP backed below.

__backend__
```
backend bk_rtmp 
 mode tcp
 balance roundrobin
 <% servers.forEach(function(server, index) { %>
 server media<%= index %> <%= server %> check maxconn 1 weight 10
 <% }); %>
```
The backend does the routing magic.  In our case it uses a simple `roundrobin` load balancing algorithm.

__http__

The http frontend and backend serve a static http response for our Route 53 healthcheck.

Now on to Part 3, the [Origin](/blog/live-streaming-origin), to learn how we route HTTP traffic to the appropriate HLS Server.