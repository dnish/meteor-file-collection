############################################################################
#     Copyright (C) 2014-2015 by Vaughn Iverson
#     fileCollection is free software released under the MIT/X11 license.
#     See included LICENSE file for details.
############################################################################

if Meteor.isServer

   express = Npm.require 'express'
   cookieParser = Npm.require 'cookie-parser'
   mongodb = Npm.require 'mongodb'
   grid = Npm.require 'gridfs-locking-stream'
   gridLocks = Npm.require 'gridfs-locks'
   dicer = Npm.require 'dicer'


   # Add this to all response headers to allow CORS for cordova with origin http://meteor.local
   allowCORSCordova = "'Access-Control-Allow-Origin': 'http://meteor.local'";

   find_mime_boundary = (req) ->
      RE_BOUNDARY = /^multipart\/.+?(?:; boundary=(?:(?:"(.+)")|(?:([^\s]+))))$/i
      result = RE_BOUNDARY.exec req.headers['content-type']
      result?[1] or result?[2]

   # Fast MIME Multipart parsing of generic HTTP POST request bodies
   dice_multipart = (req, res, next) ->

      next = share.bind_env next

      unless req.method is 'POST'
         next()
         return

      responseSent = false
      handleFailure = (msg, err = "", retCode = 500) ->
         console.error "#{msg} \n", err
         unless responseSent
            responseSent = true
            res.writeHead retCode, {'Content-Type':'text/plain'}
            res.end()

      boundary = find_mime_boundary req

      unless boundary
         handleFailure "No MIME multipart boundary found for dicer"
         return

      params = {}
      count = 0
      fileStream = null
      fileType = 'text/plain'
      fileName = 'blob'

      d = new dicer { boundary: boundary }

      d.on 'part', (p) ->
         p.on 'header', (header) ->
            RE_FILE = /^form-data; name="file"; filename="([^"]+)"/
            RE_PARAM = /^form-data; name="([^"]+)"/
            for k, v of header
               if k is 'content-type'
                  fileType = v
               if k is 'content-disposition'
                  if re = RE_FILE.exec(v)
                     fileStream = p
                     fileName = re[1]
                  else if param = RE_PARAM.exec(v)?[1]
                     data = ''
                     count++
                     p.on 'data', (d) ->
                        data += d.toString()
                     p.on 'end', () ->
                        count--
                        params[param] = data
                        if count is 0 and fileStream
                           req.multipart =
                              fileStream: fileStream
                              fileName: fileName
                              fileType: fileType
                              params: params
                           responseSent = true
                           next()
                  else
                     console.warn "Dicer part", v

            if count is 0 and fileStream
               req.multipart =
                  fileStream: fileStream
                  fileName: fileName
                  fileType: fileType
                  params: params
               responseSent = true
               next()

         p.on 'error', (err) ->
            handleFailure 'Error in Dicer while parsing multipart:', err

      d.on 'error', (err) ->
         handleFailure 'Error in Dicer while parsing parts:', err

      d.on 'finish', () ->
         unless fileStream
            handleFailure "Error in Dicer, no file found in POST"

      req.pipe(d)

   # Handle a generic HTTP POST file upload

   # This curl command should be properly handled by this code:
   # % curl -X POST 'http://127.0.0.1:3000/gridfs/fs/38a14c8fef2d6cef53c70792' \
   #        -F 'file=@"universe.png";type=image/png' -H 'X-Auth-Token: zrtrotHrDzwA4nC5'

   post = (req, res, next) ->
      # Handle filename or filetype data when included
      req.gridFS.contentType = req.multipart.fileType if req.multipart.fileType
      req.gridFS.filename = req.multipart.fileName if req.multipart.fileName

      # Write the file data.  No chunks here, this is the whole thing
      stream = @upsertStream req.gridFS
      if stream
         req.multipart.fileStream.pipe(share.streamChunker(@chunkSize)).pipe(stream)
            .on 'close', (retFile) ->
               if retFile
                  res.writeHead(200, {'Content-Type':'text/plain', 'Access-Control-Allow-Origin': 'http://meteor.local'})
                  res.end()
            .on 'error', (err) ->
               res.writeHead(500, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
               res.end()
      else
         res.writeHead(410, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
         res.end()

   # Handle a generic HTTP GET request
   # This also handles HEAD requests
   # If the request URL has a "?download=true" query, then a browser download response is triggered

   get = (req, res, next) ->

      # If range request in the header
      if req.headers['range']
        # Set status code to partial data
        statusCode = 206

        # Pick out the range required by the browser
        parts = req.headers["range"].replace(/bytes=/, "").split("-")
        start = parseInt(parts[0], 10)
        end = (if parts[1] then parseInt(parts[1], 10) else req.gridFS.length - 1)

        # Unable to handle range request - Send the valid range with status code 416
        if (start < 0) or (end >= req.gridFS.length) or (start > end) or isNaN(start) or isNaN(end)
          res.writeHead 416, { 'Content-Type':'text/plain', 'Content-Range': 'bytes ' + '*/' + req.gridFS.length }
          res.end()
          return

        # Determine the chunk size
        chunksize = (end - start) + 1

        # Construct the range request header
        headers =
            'Content-Range': 'bytes ' + start + '-' + end + '/' + req.gridFS.length
            'Accept-Ranges': 'bytes'
            'Content-Type': req.gridFS.contentType
            'Content-Length': chunksize
            'Last-Modified': req.gridFS.uploadDate.toUTCString()
            'Access-Control-Allow-Origin': 'http://meteor.local'

        # Read the partial request from gridfs stream
        unless req.method is 'HEAD'
           stream = @findOneStream(
             _id: req.gridFS._id
           ,
             range:
               start: start
               end: end
           )

      # Otherwise prepare to stream the whole file
      else
        # Set default status code
        statusCode = 200

        # Set default headers
        headers =
            'Content-type': req.gridFS.contentType
            'Content-MD5': req.gridFS.md5
            'Content-Length': req.gridFS.length
            'Last-Modified': req.gridFS.uploadDate.toUTCString()

        # Open file to stream
        unless req.method is 'HEAD'
           stream = @findOneStream { _id: req.gridFS._id }

      # Trigger download in browser, optionally specify filename.
      if (req.query.download and req.query.download.toLowerCase() == 'true') or req.query.filename
        filename = encodeURIComponent(req.query.filename ? req.gridFS.filename)
        headers['Content-Disposition'] = "attachment; filename=\"#{filename}\"; filename*=UTF-8''#{filename}"

      # If specified in url query set cache to specified value, might want to add more options later.
      if req.query.cache and not isNaN(parseInt(req.query.cache))
        headers['Cache-Control'] = "max-age=" + parseInt(req.query.cache)+", private"

      # HEADs don't have a body
      if req.method is 'HEAD'
        res.writeHead 204, headers
        res.end()
        return

      # Stream file
      if stream
         res.writeHead statusCode, headers
         stream.pipe(res)
            .on 'close', () ->
               res.end()
            .on 'error', (err) ->
               res.writeHead(500, {'Content-Type':'text/plain'})
               res.end(err)
      else
         res.writeHead(410, {'Content-Type':'text/plain'})
         res.end()

   # Handle a generic HTTP PUT request

   # This curl command should be properly handled by this code:
   # % curl -X PUT 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
   #        -T "universe.png" -H 'Content-Type: image/png' -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

   put = (req, res, next) ->

      # Handle content type if it's present
      if req.headers['content-type']
         req.gridFS.contentType = req.headers['content-type']

      # Write the file
      stream = @upsertStream req.gridFS
      if stream
         req.pipe(share.streamChunker(@chunkSize)).pipe(stream)
            .on 'close', (retFile) ->
               if retFile
                  res.writeHead(200, {'Content-Type':'text/plain', 'Access-Control-Allow-Origin': 'http://meteor.local'})
                  res.end()
            .on 'error', (err) ->
               res.writeHead(500, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
               res.end(err)
      else
         res.writeHead(404, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
         res.end("#{req.url} Not found!")

   # Handle a generic HTTP DELETE request

   # This curl command should be properly handled by this code:
   # % curl -X DELETE 'http://127.0.0.1:3000/gridfs/fs/7868f3df8425ae68a572b334' \
   #        -H 'X-Auth-Token: tEPAwXbGwgfGiJL35'

   del = (req, res, next) ->

      @remove req.gridFS
      res.writeHead(204, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
      res.end()

   # Setup all of the application specified paths and file lookups in express
   # Also performs allow/deny permission checks for POST/PUT/DELETE

   build_access_point = (http) ->

      # Loop over the app supplied http paths
      for r in http

         if r.method.toUpperCase() is 'POST'
            @router.post r.path, dice_multipart

         # Add an express middleware for each application REST path
         @router[r.method] r.path, do (r) =>

            (req, res, next) =>

               # params and queries literally named "_id" get converted to ObjectIDs automatically


               req.params._id = share.safeObjectID(req.params._id) if req.params?._id?
               req.query._id = share.safeObjectID(req.query._id) if req.query?._id?



               # Build the path lookup mongoDB query object for the gridFS files collection
               lookup = r.lookup?.bind(@)(req.params or {}, req.query or {}, req.multipart)
               unless lookup?
                  # No lookup returned, so bailing
                  res.writeHead(500, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
                  res.end()
                  return
               else
                  # Perform the collection query


                  console.log(req.params._id)
                  console.log(req.query._id )
                  #if req.query.resumableIdentifier
                      #lookup = {_id: new Mongo.ObjectID(req.query.resumableIdentifier)};  #  Todo: This workaround only works if you've defined '_id' as identifier, so it will break the package if you use f.e. md5 as identifier. We need this workaround lookup has the value {_id:null} when uploading via Cordova.
                  req.gridFS = @findOne lookup
                  unless req.gridFS

                     res.writeHead(404, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
                     res.end()
                     return

                  # Make sure that the requested method is permitted for this file in the allow/deny rules
                  switch req.method
                     when 'HEAD', 'GET'
                        unless share.check_allow_deny.bind(@) 'read', req.meteorUserId, req.gridFS
                           res.writeHead(403, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
                           res.end()
                           return
                     when 'POST', 'PUT'
                        unless share.check_allow_deny.bind(@) 'write', req.meteorUserId, req.gridFS
                           res.writeHead(403, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
                           res.end()
                           return
                     when 'DELETE'
                        unless share.check_allow_deny.bind(@) 'remove', req.meteorUserId, req.gridFS
                           res.writeHead(403, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
                           res.end()
                           return
                     else
                        res.writeHead(500, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
                        res.end()
                        return

                  next()

      @router.route('/*')



         .options (req, res, next) ->  # Needed for CORS support, browser sends options to check if CORDS is supported by server
            res.writeHead(200, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
            res.end()
            return
            next()

         .all (req, res, next) ->  # Make sure a file has been selected by some rule


            unless req.gridFS
               res.writeHead(404, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
               res.end()
               return
            next()

      # Loop over the app supplied http paths
      for r in http when typeof r.handler is 'function'
            # Add an express middleware for each custom request handler
            @router[r.method] r.path, r.handler.bind(@)

      # Add all of generic request handling methods to the express route
      @router.route('/*')
         .head(get.bind(@))   # Generic HTTP method handlers
         .get(get.bind(@))
         .put(put.bind(@))
         .post(post.bind(@))
         .delete(del.bind(@))
         .all (req, res, next) ->   # Unkown methods are denied
            res.writeHead(500, {'Content-Type':'text/plain','Access-Control-Allow-Origin': 'http://meteor.local'})
            res.end()

   # Performs a meteor userId lookup by hased access token

   lookup_userId_by_token = (authToken) ->
      userDoc = Meteor.users?.findOne
         'services.resume.loginTokens':
            $elemMatch:
               hashedToken: Accounts?._hashLoginToken(authToken)
      return userDoc?._id or null

   # Express middleware to convert a Meteor access token provided in an HTTP request
   # to a Meteor userId attached to the request object as req.meteorUserId

   handle_auth = (req, res, next) ->
      unless req.meteorUserId?
         # Lookup userId if token is provided in HTTP heder
         if req.headers?['x-auth-token']?
            req.meteorUserId = lookup_userId_by_token req.headers['x-auth-token']
         # Or as a URL query of the same name
         else if req.cookies?['X-Auth-Token']?
            req.meteorUserId = lookup_userId_by_token req.cookies['X-Auth-Token']
         else
            req.meteorUserId = null
      next()

   # Set up all of the middleware, including optional support for Resumable.js chunked uploads
   share.setupHttpAccess = (options) ->
      r = express.Router()
      r.use express.query()   # Parse URL query strings
      r.use cookieParser()    # Parse cookies
      r.use handle_auth       # Turn x-auth-tokens into Meteor userIds
      WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(r))

      # Set up support for resumable.js if requested
      if options.resumable
         options.http = share.resumable_paths.concat options.http

      # Setup application HTTP REST interface
      @router = express.Router()
      build_access_point.bind(@)(options.http, @router)
      WebApp.rawConnectHandlers.use(@baseURL, share.bind_env(@router))
