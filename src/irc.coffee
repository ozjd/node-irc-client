# out: ../lib/$1.js, sourcemap: true

net = require 'net'
tls = require 'tls'
os = require 'os'
{EventEmitter} = require 'events'

module.exports = class IRCClient extends EventEmitter
  constructor: (@server, @port, @nickName, @userName = 'NodeClient', @realName = '') ->
    @realName = if @realName is '' then ' ' else @realName # Can't be blank.
    @conn = null
    @version = 'v0.1.1'
    # @_sendQ = '' # TODO: Implement (for before connection)
    @vars =
      fixed:
        me: null
      temp: {}
    do @connect

  connect: ->
    type = if -1 isnt @port.indexOf '+' then tls else net
    @conn = type.connect
      host: @server
      port: parseInt @port
      rejectUnauthorized: false # Most servers use Unsigned Certificates. TODO: Add option
    @_setEmitters @conn
    @ # Returning self, so we can chain calls.

  send: (data) ->
    @conn.write "#{ data }\r\n"
    @emit 'RAW', 'out', data
    @

  ctcp: (target, command, message) ->
    @msg target, "\u0001#{ command }#{ if message? then ' ' + message }\u0001"

  ctcpreply: (target, command, message) ->
    @notice target, "\u0001#{ command }#{ if message? then ' ' + message }\u0001"

  describe: (target, message) ->
    @ctcp target, 'ACTION', message

  join: (channels) ->
    @send "JOIN #{ channels }"

  kick: (channel, user, reason) ->
    @send "KICK #{ channel } #{ user } :#{ reason }"

  kill: (user, reason) ->
    @send "KILL #{ user } :#{ reason }"

  msg: (target, message) ->
    @send "PRIVMSG #{ target } :#{ message }"

  notice: (target, message) ->
    @send "NOTICE #{ target } :#{ message }"

  part: (channels) ->
    @send "PART #{ channels }"

  quit: (message) ->
    @send "QUIT :#{ message }"

  # Some mIRCish helpful identifiers... (very incomplete)
  $address: -> @vars.temp.prefix?.split('!')[1] ? @$null() #TODO: Needs more work
  $asc: (s) -> s.toString().charCodeAt(0) ? @$null # Alt?: String::charCodeAt.apply s.toString(), arguments
  $chr: (n) -> String.fromCharCode(n) ? @$null
  $cr: -> "\r"
  $crlf: -> @$cr + @$lf
  $ctime: (s) -> Math.floor new Date(s.toString()).getTime() / 1000
  $false: -> false
  $len: (s) -> s.toString().length ? @$null
  $lf: -> "\n"
  $me: -> @vars.fixed.me ? @$null()
  $nick: -> @vars.temp.prefix?.split('!')[0] ? @$null()
  $null: -> ''
  $server: -> @server ? @$null
  $true: -> true
  $os: -> "#{ os.type() } (#{ os.arch() })"
  $pi: -> '3.14159265358979323846'

  _setEmitters: (conn) ->
    conn.on 'close', (had_error) =>
      @conn = undefined
      @emit 'DISCONNECT', had_error
    conn.on 'connect', =>
      @send "USER #{ @userName } * * :#{ @realName }"
      @send "NICK #{ @nickName }"
      @emit 'CONNECT'
    conn.on 'data', (buffer) =>
      @_parseBuffer buffer

  _parseBuffer: (buffer) ->
    data = @_unprocessed + buffer.toString 'utf8'
    lines = data.split('\r').join('\n').split('\n')
    @_unprocessed = lines.splice lines.length - 1
    for data in lines
      if data isnt ''
        @emit 'raw', 'in', data
        @_parseData data

  _parseData: (data) ->
    prefix = null
    command = null
    params = []
    completed = false
    words = data.split(' ')
    words.map (cV, i, a) -> # Break line up into parts
      if completed is false
        if prefix is null and ':' is cV.charAt 0 # Starts with a ':'
          prefix = cV.substr 1
        else if command is null
          if prefix is null
            prefix = ''
          command = cV
        else
          if ':' isnt cV.charAt 0
            params.push cV
          else
            params.push words.slice(i).join(' ').substr 1
            completed = true
    @_parseCommand command, prefix, params

  _parseCommand: (command, prefix, params) ->
    @vars.temp.prefix = prefix # Set temporary vars
    cmd = command.toUpperCase()
    switch cmd
      when 'PRIVMSG', 'NOTICE' # Check for CTCP
        [target, message] = params
        if message.length >= 3 and message.charCodeAt(0) is 1 and
           message.charCodeAt(message.length - 1) is 1 # This is a type of CTCP
          message = message.substr 1, message.length - 2 # Redefine message
          if cmd is 'PRIVMSG' and message is 'VERSION' and target is @$me() # CTCP Version (Private Only)
            @ctcpreply @$nick(), message, "Node.JS IRC Client #{ @version } on Node.js #{ process.version }"
          if cmd is 'PRIVMSG' and message.substr(0, 7) is 'ACTION ' # Event: ACTION
            @emit.apply @, ['ACTION', prefix, target, message.substr 7]
          else # Event: CTCP / CTCPREPLY
            words = message.split ' '
            CTCPcommand = words.slice(0, 1).join(' ').toUpperCase()
            params = words.slice(1).join ' '
            type = if cmd is 'PRIVMSG' then 'CTCP' else 'CTCPREPLY'
            @emit.apply @, [type, prefix, target, CTCPcommand, message.substr CTCPcommand.length + 1]
        else
          type = if cmd is 'PRIVMSG' then 'TEXT' else cmd # Event: PRIVMSG / NOTICE
          @emit.apply @, [type, prefix, target, message]
      when 'PING' # Event: PING (Very Important!)
        @send "PONG :#{ params.join ' ' }"
      when '001'
        @vars.fixed.me = params[0] # Store own nickname
        @emit 'LOGON'
    if -1 isnt ['NICK', 'QUIT', 'JOIN', 'PART', 'MODE', 'TOPIC', 'INVITE',
                'KICK', 'KILL', 'PING', 'PONG'].indexOf cmd # Event: (Supported)
      @emit.apply @, [cmd, prefix].concat params
    @emit "raw#{ cmd }", params, prefix # Event: All (raw)
    @vars.temp = {} # Reset temporary vars
