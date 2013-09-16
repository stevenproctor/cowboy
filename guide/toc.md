Cowboy User Guide
=================

The Cowboy User Guide explores the modern Web and how to make
best use of Cowboy for writing powerful web applications.

Introducing Cowboy
------------------

 *  [Introduction](introduction.md)
 *  [The modern Web](modern_web.md)
 *  [Erlang and the Web](erlang_web.md)
 *  [Erlang for beginners](erlang_beginners.md)
 *  [Getting started](getting_started.md)

HTTP
----

 *  [The life of a request](http_req_life.md)
 *  [Routing](routing.md)
 *  Handling plain HTTP requests
 *  The Req object
 *  Reading the request body
 *  Sending a response

Static files
------------

 *  [Static handlers](static_handlers.md)
 *  Distributed CDN solutions

REST
----

 *  REST principles
 *  Media types explained
 *  HTTP caching
 *  Handling REST requests
 *  HEAD/GET requests flowchart
 *  POST/PUT/PATCH requests flowchart
 *  DELETE requests flowchart
 *  OPTIONS requests flowchart
 *  Designing a REST API

Multipart
---------

 *  Understanding multipart
 *  Multipart requests
 *  Multipart responses

Server push technologies
------------------------

 *  Push technologies
 *  Using loop handlers for server push
 *  CORS

Using Websocket
---------------

 *  The Websocket protocol
 *  Handling Websocket connections

Advanced HTTP
-------------

 *  Authentication
 *  Sessions

Advanced Cowboy usage
---------------------

 *  Optimization guide
 *  [Hooks](hooks.md)
 *  [Middlewares](middlewares.md)
 *  Access and error logs
 *  Handling broken clients
   *  HTTP header names
   *  HTTP/1.1 streaming not chunked




Using Cowboy
------------

 *  [Handlers](handlers.md)
   *  Purpose
   *  Protocol upgrades
   *  Custom protocol upgrades
 *  [HTTP handlers](http_handlers.md)
   *  Purpose
   *  Usage
 *  [Loop handlers](loop_handlers.md)
   *  Purpose
   *  Usage
 *  [Websocket handlers](ws_handlers.md)
   *  Purpose
   *  Usage
 *  [REST handlers](rest_handlers.md)
   *  Purpose
   *  Usage
   *  Flow diagram
   *  Methods
   *  Callbacks
   *  Meta data
   *  Response headers
   *  Purpose
   *  Usage
   *  MIME type
 *  [Request object](req.md)
   *  Purpose
   *  Request
   *  Request body
   *  Multipart request body
   *  Response
   *  Chunked response
   *  Response preconfiguration
   *  Closing the connection
   *  Reducing the memory footprint
 *  [Internals](internals.md)
   *  Architecture
   *  One process for many requests
   *  Lowercase header names
   *  Improving performance
 *  [Resources](resources.md)
   *  Frameworks
   *  Helper libraries
   *  Articles
