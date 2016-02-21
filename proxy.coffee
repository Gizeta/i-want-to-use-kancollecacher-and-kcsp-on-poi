Promise = require 'bluebird'
async = Promise.coroutine
zlib = Promise.promisifyAll require 'zlib'
EventEmitter = require 'events'
url = require 'url'
net = require 'net'
http = require 'http'
path = require 'path'
querystring = require 'querystring'
caseNormalizer = require 'header-case-normalizer'
fs = Promise.promisifyAll require 'fs-extra'
request = Promise.promisifyAll require 'request'
requestAsync = Promise.promisify request, multiArgs: true
mime = require 'mime'
socks = require 'socks5-client'
SocksHttpAgent = require 'socks5-http-client/lib/Agent'
PacProxyAgent = require 'pac-proxy-agent'


uuid = require 'node-uuid'
{log, warn, error} = remote.require './lib/utils'
{_, $, config} = window
originProxy = window.proxy

resolveBody = (encoding, body) ->
  return new Promise async (resolve, reject) ->
    try
      decoded = null
      switch encoding
        when 'gzip'
          decoded = yield zlib.gunzipAsync body
        when 'deflate'
          decoded = yield zlib.inflateAsync body
        else
          decoded = body
      decoded = decoded.toString()
      decoded = decoded.substring(7) if decoded.indexOf('svdata=') == 0
      decoded = JSON.parse decoded
      resolve decoded
    catch e
      reject e
isStaticResource = (pathname) ->
  return true if pathname.startsWith('/kcs/') && pathname.indexOf('Core.swf') == -1
  return true if pathname.startsWith('/gadget/')
  return true if pathname.startsWith('/kcscontents/')
  return false
getCachePath = (pathname) ->
  dir = config.get 'poi.cachePath', remote.getGlobal('DEFAULT_CACHE_PATH')
  path.join dir, pathname
findHack = (pathname) ->
  loc = getCachePath pathname
  sp = loc.split '.'
  ext = sp.pop()
  sp.push 'hack'
  sp.push ext
  loc = sp.join '.'
  try
    fs.accessSync loc, fs.R_OK
    return loc
  catch
    return null
findCache = (pathname) ->
  loc = getCachePath pathname
  try
    fs.accessSync loc, fs.R_OK
    return loc
  catch
    return null

# Network error retries
retries = config.get 'poi.proxy.retries', 0

PacAgents = {}
resolve = (req) ->
  switch config.get 'proxy.use'
    # HTTP Request via SOCKS5 proxy
    when 'socks5'
      return _.extend req,
        agentClass: SocksHttpAgent
        agentOptions:
          socksHost: config.get 'proxy.socks5.host', '127.0.0.1'
          socksPort: config.get 'proxy.socks5.port', 1080
    # HTTP Request via HTTP proxy
    when 'http'
      host = config.get 'proxy.http.host', '127.0.0.1'
      port = config.get 'proxy.http.port', 8118
      requirePassword = config.get 'proxy.http.requirePassword', false
      username = config.get 'proxy.http.username', ''
      password = config.get 'proxy.http.password', ''
      useAuth = requirePassword && username isnt '' && password isnt ''
      strAuth = "#{username}:#{password}@"
      return _.extend req,
        proxy: "http://#{if useAuth then strAuth else ''}#{host}:#{port}"
    # PAC
    when 'pac'
      uri = config.get('proxy.pacAddr')
      PacAgents[uri] ?= new PacProxyAgent(uri)
      _.extend req,
        agent: PacAgents[uri]
    # Directly
    else
      return req

class HackableProxy
  constructor: ->
    @load()
  load: ->
    self = originProxy
    # HTTP Requests
    @server = http.createServer (req, res) ->
      delete req.headers['proxy-connection']
      # Disable HTTP Keep-Alive
      req.headers['connection'] = 'close'
      parsed = url.parse req.url
      isGameApi = parsed.pathname.startsWith '/kcsapi'
      cacheFile = null
      if isStaticResource(parsed.pathname)
        cacheFile = findHack(parsed.pathname) || findCache(parsed.pathname)
      reqBody = new Buffer(0)
      # Get all request body
      req.on 'data', (data) ->
        reqBody = Buffer.concat [reqBody, data]
      req.on 'end', async ->
        try
          options =
            method: req.method
            url: req.url
            headers: req.headers
            encoding: null
            followRedirect: false
            timeout: 30000
          # Add body to request
          if reqBody.length > 0
            options = _.extend options,
              body: reqBody
          # Use cache file
          if cacheFile
            stats = yield fs.statAsync cacheFile
            # Cache is new
            if req.headers['if-modified-since']? && (new Date(req.headers['if-modified-since']) >= stats.mtime)
              res.writeHead 304,
                'Server': 'nginx'
                'Last-Modified': stats.mtime.toGMTString()
              res.end()
            # Cache is old
            else
              data = yield fs.readFileAsync cacheFile
              res.writeHead 200,
                'Server': 'nginx'
                'Content-Length': data.length
                'Content-Type': mime.lookup cacheFile
                'Last-Modified': stats.mtime.toGMTString()
              res.end data
          # Enable retry for game api
          else if isGameApi
            success = false
            useKcsp = config.get 'plugin.iwukkp.kcsp.enabled', false
            kcspHost = config.get 'plugin.iwukkp.kcsp.host', ''
            kcspPort = config.get 'plugin.iwukkp.kcsp.port', ''
            if useKcsp && kcspHost isnt '' && kcspPort isnt ''
              kcspRetries = 600
              options = _.extend options,
                'timeout': 3000
              options.headers['request-uri'] = options.url
              options.headers['cache-token'] = uuid.v4()
              options.url = options.url.replace(/:\/\/(.+?)\//, "://#{kcspHost}:#{kcspPort}/")
              for i in [0..kcspRetries]
                break if success
                try
                  # Emit request event to plugins
                  self.emit 'game.on.request', req.method, parsed.pathname, JSON.stringify(querystring.parse reqBody.toString())
                  # Create remote request
                  [response, body] = yield requestAsync resolve options
                  res.writeHead response.statusCode, response.headers
                  res.end body
                  # Emit response events to plugins
                  resolvedBody = yield resolveBody response.headers['content-encoding'], body
                  if !resolvedBody?
                    throw new Error('Empty Body')
                  if response.statusCode == 200
                    success = true
                    if resolvedBody.api_result is 1
                      resolvedBody = resolvedBody.api_data if resolvedBody.api_data?
                      self.emit 'game.on.response', req.method, parsed.pathname, JSON.stringify(resolvedBody),  JSON.stringify(querystring.parse reqBody.toString())
                  else
                    success = true if response.statusCode == 403 || response.statusCode == 410
                    self.emit 'network.invalid.code', response.statusCode
                catch e
                  error "Api failed: #{req.method} #{req.url} #{e.toString()}"
                  self.emit 'network.error.retry', i + 1 if i < kcspRetries
                # Delay 500ms for retry
                yield Promise.delay(500) unless success
            else
              for i in [0..retries]
                break if success
                try
                  # Emit request event to plugins
                  self.emit 'game.on.request', req.method, parsed.pathname, JSON.stringify(querystring.parse reqBody.toString())
                  # Create remote request
                  [response, body] = yield requestAsync resolve options
                  success = true
                  res.writeHead response.statusCode, response.headers
                  res.end body
                  # Emit response events to plugins
                  resolvedBody = yield resolveBody response.headers['content-encoding'], body
                  if !resolvedBody?
                    throw new Error('Empty Body')
                  if response.statusCode == 200
                    if resolvedBody.api_result is 1
                      resolvedBody = resolvedBody.api_data if resolvedBody.api_data?
                      self.emit 'game.on.response', req.method, parsed.pathname, JSON.stringify(resolvedBody),  JSON.stringify(querystring.parse reqBody.toString())
                  else if response.statusCode == 503
                    throw new Error('Service unavailable')
                  else
                    self.emit 'network.invalid.code', response.statusCode
                catch e
                  error "Api failed: #{req.method} #{req.url} #{e.toString()}"
                  self.emit 'network.error.retry', i + 1 if i < retries
                # Delay 3s for retry
                yield Promise.delay(3000) unless success
          else
            [response, body] = yield requestAsync resolve options
            res.writeHead response.statusCode, response.headers
            res.end body
          if parsed.pathname in ['/kcs/mainD2.swf', '/kcsapi/api_start2', '/kcsapi/api_get_member/basic']
            self.emit 'game.start'
          else if req.url.startsWith 'http://www.dmm.com/netgame/social/application/-/purchase/=/app_id=854854/payment_id='
            self.emit 'game.payitem'
        catch e
          error "#{req.method} #{req.url} #{e.toString()}"
          if req.url.startsWith('http://www.dmm.com/netgame/') or req.url.indexOf('/kcs/') != -1 or req.url.indexOf('/kcsapi/') != -1
            self.emit 'network.error'
    # HTTPS Requests
    @server.on 'connect', (req, client, head) ->
      delete req.headers['proxy-connection']
      # Disable HTTP Keep-Alive
      req.headers['connection'] = 'close'
      remoteUrl = url.parse "https://#{req.url}"
      remote = null
      switch config.get 'proxy.use'
        when 'socks5'
          # Write data directly to SOCKS5 proxy
          remote = socks.createConnection
            socksHost: config.get 'proxy.socks5.host', '127.0.0.1'
            socksPort: config.get 'proxy.socks5.port', 1080
            host: remoteUrl.hostname
            port: remoteUrl.port
          remote.on 'connect', ->
            client.write "HTTP/1.1 200 Connection Established\r\nConnection: close\r\n\r\n"
            remote.write head
          client.on 'data', (data) ->
            remote.write data
          remote.on 'data', (data) ->
            client.write data
        # Write data directly to HTTP proxy
        when 'http'
          host = config.get 'proxy.http.host', '127.0.0.1'
          port = config.get 'proxy.http.port', 8118
          # Write header to http proxy
          msg = "CONNECT #{remoteUrl.hostname}:#{remoteUrl.port} HTTP/#{req.httpVersion}\r\n"
          for k, v of req.headers
            msg += "#{caseNormalizer(k)}: #{v}\r\n"
          msg += "\r\n"
          remote = net.connect port, host, ->
            remote.write msg
            remote.write head
            client.pipe remote
            remote.pipe client
        # Connect to remote directly
        else
          remote = net.connect remoteUrl.port, remoteUrl.hostname, ->
            client.write "HTTP/1.1 200 Connection Established\r\nConnection: close\r\n\r\n"
            remote.write head
            client.pipe remote
            remote.pipe client
      client.on 'end', ->
        remote.end()
      remote.on 'end', ->
        client.end()
      client.on 'error', (e) ->
        error e
        remote.destroy()
      remote.on 'error', (e) ->
        error e
        client.destroy()
      client.on 'timeout', ->
        client.destroy()
        remote.destroy()
      remote.on 'timeout', ->
        client.destroy()
        remote.destroy()
    @server.on 'error', (err) =>
      error err
    @server.timeout = 40 * 60 * 1000
    webview = $('kan-game webview')
    handleStopLoading = =>
      webview.removeEventListener 'did-stop-loading', handleStopLoading
      @listenPort = originProxy.server.address().port
      originProxy.server.close()
      @server.listen @listenPort, '127.0.0.1', =>
        log "Switch to hackable proxy"
    webview.addEventListener 'did-stop-loading', handleStopLoading
  setMaxListeners: (n) ->
    originProxy.setMaxListeners n
  addListener: (type, listener) ->
    originProxy.addListener(type, listener)
  removeListener: (type, listener) ->
    originProxy.removeListener(type, listener)

module.exports = new HackableProxy()