Promise = require 'bluebird'
async = Promise.coroutine
zlib = Promise.promisifyAll require 'zlib'
url = require 'url'
net = require 'net'
http = require 'http'
querystring = require 'querystring'
caseNormalizer = require 'header-case-normalizer'
request = Promise.promisifyAll require 'request'
requestAsync = Promise.promisify request, multiArgs: true
socks = require 'socks5-client'
SocksHttpAgent = require 'socks5-http-client/lib/Agent'
PacProxyAgent = require 'pac-proxy-agent'

uuid = require 'node-uuid'
{log, warn, error} = remote.require './lib/utils'
{_, $, config, proxy} = window

webview = $('kan-game webview')

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

# Modify api_start2 response
modifyShipGraph = (resolvedBody) ->
  modFile = findCache('ApiModify.json')
  return unless modFile
  modData = require modFile
  for data in modData
    shipGraph = _.find resolvedBody.api_data.api_mst_shipgraph, (e) -> e.api_filename == data.api_filename
    continue if shipGraph == null
    ship = _.find resolvedBody.api_data.api_mst_ship, (e) -> e.api_id == shipGraph.api_id
    for key of data
      continue if key == 'api_id' || key == 'api_filename'
      continue if shipGraph[key] = null
      shipGraph[key] = data[key]
    ship.api_name = data.api_name unless data.api_name == null
    ship.api_getmes = data.api_getmes unless data.api_getmes == null
  return resolvedBody

getRequestListener = ->
  require('electron').app =
    commandLine:
      appendSwitch: ->
        log "Cannot deal with commandLine in render process"
  originProxy = process.mainModule.require('./lib/proxy')
  originServer = originProxy.server
  originServer.close()
  originProxy.emit = proxy.emit
  return originServer._events["request"]

originRequestListener = getRequestListener()

class HackableProxy
  constructor: ->
    @listenPort = proxy.port
    @load()
  load: ->
    @server = http.createServer (req, res) ->
      parsed = url.parse req.url
      isGameApi = parsed.pathname.startsWith('/kcsapi') && req.method == 'POST'
      useKcsp = config.get 'plugin.iwukkp.kcsp.enabled', false
      kcspHost = config.get 'plugin.iwukkp.kcsp.host', ''
      kcspPort = config.get 'plugin.iwukkp.kcsp.port', ''
      unless isGameApi && useKcsp && kcspHost isnt '' && kcspPort isnt ''
        originRequestListener(req, res)
        return
      delete req.headers['proxy-connection']
      # Disable HTTP Keep-Alive
      req.headers['connection'] = 'close'
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
            timeout: if isGameApi then 5000 else 120000
          # Add body to request
          if reqBody.length > 0
            options = _.extend options,
              body: reqBody
          domain = req.headers.origin
          pathname = parsed.pathname
          requrl = req.url
          success = false
          retries = 500
          options.headers['request-uri'] = options.url
          options.headers['cache-token'] = uuid.v4()
          options.url = options.url.replace(/:\/\/(.+?)\//, "://#{kcspHost}:#{kcspPort}/")
          for i in [0..retries]
            break if success
            try
              # Emit request event to plugins
              reqBody = JSON.stringify(querystring.parse reqBody.toString())
              proxy.emit 'network.on.request', req.method, [domain, pathname, requrl], reqBody
              # Create remote request
              [response, body] = yield requestAsync resolve options
              # Emit response events to plugins
              try
                resolvedBody = yield resolveBody response.headers['content-encoding'], body
              catch e
                # Unresolveable binary files are not retried
                break
              if pathname == '/kcsapi/api_start2' && config.get('plugin.iwukkp.shipgraph.enable', false)
                resolvedBody = modifyShipGraph resolvedBody
                body = 'svdata=' + JSON.stringify(resolvedBody)
                response.headers['content-encoding'] = ''
              res.writeHead response.statusCode, response.headers
              res.end body
              if !resolvedBody?
                throw new Error('Empty Body')
              if response.statusCode == 200
                success = true
                proxy.emit 'network.on.response', req.method, [domain, pathname, requrl], JSON.stringify(resolvedBody), reqBody
              else
                success = true if response.statusCode == 403 || response.statusCode == 410
                proxy.emit 'network.error', [domain, pathname, requrl], response.statusCode
            catch e
              error "Api failed: #{req.method} #{req.url} #{e.toString()}"
              proxy.emit 'network.error.retry', [domain, pathname, requrl], i + 1 if i < retries
            # Delay 1000ms for retry
            yield Promise.delay(1000) unless success
        catch e
          error "#{req.method} #{req.url} #{e.toString()}"
          proxy.emit 'network.error', [domain, pathname, requrl]
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
    @server.on 'error', (err) ->
      error err
    @server.timeout = 40 * 60 * 1000
  startup: ->
    proxy.server.close()
    @server.listen @listenPort, '127.0.0.1', ->
      log "Hackable proxy started"
  start: ->
    if webview.isLoading()
      handleStopLoading = =>
        webview.removeEventListener 'did-stop-loading', handleStopLoading
        @startup()
      webview.addEventListener 'did-stop-loading', handleStopLoading
    else
      @startup()
  stop: ->
    @server.close()
    proxy.load().close()
    proxy.server.listen @listenPort, '127.0.0.1', ->
      log "Origin proxy started"

module.exports = new HackableProxy()
