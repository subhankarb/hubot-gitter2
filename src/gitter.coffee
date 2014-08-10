{EventEmitter}        = require 'events'
util                  = require 'util'
Gitter                = require 'node-gitter'
{Adapter,TextMessage} = require 'hubot'


ROOM_EVENTS = ['message']
ROOM_ID_REGEXP = /^[a-f0-9]{24}$/
MAX_MESSAGE_SIZE = 1024

class GitterAdapter extends Adapter
  # An adapter is a specific interface to a chat source for robots.
  #
  # robot - A Robot instance.
  constructor: (@robot) ->
    super
    @_knownRooms = {}


  # Public: Raw method for sending data back to the chat source. Extend this.
  #
  # envelope - A Object with message, room and user details.
  # strings  - One or more Strings for each message to send.
  #
  # Returns nothing.
  send: (envelope, strings...) ->
    if strings.length > 0
      string = strings.shift()
      if typeof(string) is 'function' or string instanceof Function
        string()
        @send envelope, strings...
      else
        strings.unshift(string)
        # find the room, and send the message to it
        @_resolveRoom(envelope.room, yes, (err, room) =>
          return @_log 'error', "unable to find/join room #{ envelope.room }: #{ err }" if err
          # make sure not line is empty
          lines = []
          for line in strings
            if line is undefined or line is null or line is ''
              lines.push ' '
            else
              lines.push "#{ line }"
          # keep track of how many messages has been asked to send
          realTotal = lines.length
          # we need to join lines without going over the max message size
          chunks = []
          while lines.length
            chunk = []
            size = 0
            while lines.length
              # here we check if we have at least one line in the chunk else we'll loop infinitely
              ls = lines[0].length + 1
              break if chunk.length > 0 and size + ls >= MAX_MESSAGE_SIZE
              chunk.push lines.shift()
              size += ls
            # we create a new chunk with all possible lines that we could join
            chunks.push chunk.join('\n')
          # now we have optimized the # of messages
          lines = chunks.slice()
          if lines.length isnt realTotal
            @_log "compressed #{ realTotal } lines into #{ lines.length }"
          # now we can send all lines
          if lines.length < 1
            # make sure we are not sending an empty message
            @_log 'warning', "not sending an empty message in room #{ room.uri }"
          else
            # send all lines, one by one
            total = lines.length
            @_log "sending #{ total } messages to the room #{ room.uri }"
            # this closure is responsible of sending one line and handling possible error of previous line
            next = ((err) =>
              if err
                still = " (#{ lines.length + 1 } of #{ total } line(s) not sent)"
                @_log 'error', "error sending a message to room #{ room.uri }#{ still }: #{ err }"
              else if (line = lines.shift())
                room.send(line).then(-> next()).fail(next)
              else
                @_log "message of #{ total } line(s) sent to room #{ room.uri }"
              # be sure to not return nothing
              return
            )
            next()
        )
    return


  # Public: Raw method for sending emote data back to the chat source.
  # Defaults as an alias for send
  #
  # envelope - A Object with message, room and user details.
  # strings  - One or more Strings for each message to send.
  #
  # Returns nothing.
  emote: (envelope, strings...) ->
    @send envelope, strings...


  # Public: Raw method for building a reply and sending it back to the chat
  # source. Extend this.
  #
  # envelope - A Object with message, room and user details.
  # strings  - One or more Strings for each reply to send.
  #
  # Returns nothing.
  reply: (envelope, strings...) ->
    room = envelope.room or envelope.message?.room or envelope.message?.user?.room or envelope.user?.room
    if room
      @send {room}, strings...
    else
      @_log 'error', "failed to reply to #{ envelope }"
      console.log "failed to reply to", envelope
    return


  # Public: Raw method for setting a topic on the chat source. Extend this.
  #
  # envelope - A Object with message, room and user details.
  # strings  - One more more Strings to set as the topic.
  #
  # Returns nothing.
  topic: (envelope, strings...) ->
    # Gitter does not support setting room topic yet


  # Public: Raw method for playing a sound in the chat source. Extend this.
  #
  # envelope - A Object with message, room and user details.
  # strings  - One or more strings for each play message to send.
  #
  # Returns nothing
  play: (envelope, strings...) ->
    # Gitter does not support playing sounds yet


  # Public: Raw method for invoking the bot to run. Extend this.
  #
  # Returns nothing.
  run: ->
    token = process.env.HUBOT_GITTER_TOKEN or ''
    rooms = process.env.HUBOT_GITTER_ROOMS or ''
    unless token
      @_log 'error', err = 'you must define HUBOT_GITTER_TOKEN to use Gitter adapter'
      throw new Error(err)
    @gitter = new Gitter(token)
    # joining rooms
    @_log "rooms to join: #{ rooms }"
    for uri in rooms.split(/\s*,\s*/g) when uri isnt ''
      @_resolveRoom(uri, yes, (err, room) =>
        return @_log 'error', "unable to join room #{ uri }" if err
        # registering known users
        room.users()
        .then((users) =>
          for user in users
            @_resolveHubotUser(user)
        )
        .fail((err) =>
          @_log 'error', "error trying to get the list of users in room #{ room.uri }: #{ err }"
        )
      )
    # we are connected, ready to start
    @emit 'connected'


  # Public: Raw method for shutting the bot down. Extend this.
  #
  # Returns nothing.
  close: ->


  # Private: Resolve a Gitter room by URI or object, joining it if it is not joined yet
  #
  # uriOrRoom - The room object or its URI
  # join      - Defines whether to join or not the room. Default: false
  # callback  - The method to call when the room is found or if error
  _resolveRoom: (uriOrRoom, join, callback) ->
    #@_log "_resolveRoom(#{ Array::join.call arguments, ', ' })"
    if arguments.length < 3
      callback = join
      join = no
    if typeof(uriOrRoom) is 'string' or uriOrRoom instanceof String
      if ROOM_ID_REGEXP.test(uriOrRoom)
        # it is a room ID
        uriOrRoom = id: uriOrRoom
      else
        # an URI has been given
        uri = uriOrRoom
        if (room = @_findRoomBy 'uri', uri) and (not join or @_hasJoinedRoom room)
          # we know the room and we joined it already
          callback null, room
        else
          # we didn't join the room yet
          @_joinRoom uri, callback
        return

    if (id = uriOrRoom?.id)
      # we got a room object
      # this closure will join if needed and finally call our cb
      end = ((room) =>
        if join and not @_hasJoinedRoom(room)
          @_joinRoom room.uri, callback
        else
          callback null, room
      )
      if (room = @_findRoomBy id)
        # we know the room
        end room
      else
        # we try to find the room
        @gitter.rooms.find(id, (err, room) =>
          return callback new Error(err.err) if err
          @_registerRoom room
          end room
        )

    else
      # unrecognized room
      callback new Error("unrecognized room #{ uriOrRoom }")


  # Private: Join a room given its URI
  #
  # uri      - The URI of the room to join
  # callback - The closure to call once joined or in error
  _joinRoom: (uri, callback) ->
    #@_log "_joinRoom(#{ Array::join.call arguments, ', ' })"
    throw new Error("Invalid room URI: #{ uri }") unless uri and (typeof(uri) is 'string' or uri instanceof String)
    @gitter.rooms.join(uri, (err, room) =>
      if err
        @_log 'error', msg = "unable to join room #{ uri }: #{ err.err }"
        callback new Error(msg)
      else
        @_registerRoom room, yes
        callback null, room
    )


  # Private: Register a new known room or update existing one
  #
  # room   - The room object to register or update
  # joined - Whether to register the room as joined/left
  _registerRoom: (room, joined) ->
    #@_log "_registerRoom(#{ room.uri })"
    throw new Error("invalid room") unless room?.id and room?.uri
    id = "#{room.id}"
    if (r = @_knownRooms[id])
      r.name = room.name
    else
      @_log "registered new room #{ room.uri }"
      @_knownRooms[id] = r = room
      events = r.listen()
      events.emit = ((original) =>
        (event, args...) =>
          @_log "will emit #{ event } on #{ room.uri } with [#{ args.join ', ' }]"
          original.apply events, arguments
      )(events.emit)
    if arguments.length is 2
      @_hasJoinedRoom r, joined
    r


  # Private: Get a known room object with the given property lookup
  #
  # property - The property to look for. Default: 'id'
  # value    - The searched value for that property
  _findRoomBy: (property, value) ->
    #@_log "_findRoomBy(#{ Array::join.call arguments, ', ' })"
    if arguments.length is 1
      value = property
      property = 'id'
    if value is undefined or value is null
      undefined
    else if property is 'id'
      @_knownRooms["#{ value }"]
    else
      for room of @_knownRooms when room[property] is value
        return room
      undefined


  # Private: Finds whether we joined the given room yet or not
  #
  # room   - The room object
  # joined - If set, will flag the room as joined or not
  _hasJoinedRoom: (room, joined) ->
    #@_log "_hasJoinedRoom(#{ Array::join.call arguments, ', ' })"
    if arguments.length is 2
      if Boolean(joined) isnt Boolean(room._joined)
        # we need to start/stop listening to new messages on that room
        method = room.events[if joined then 'on' else 'off'].bind room.events
        for event in ROOM_EVENTS
          method event, @_handleRoomEvent.bind(@, event, room)
        @_log "#{ if joined then 'started' else 'stopped' } listening events from #{ room.uri }"
      room._joined = Boolean joined
    Boolean room._joined


  # Private: Handles a room event
  #
  # event - The event name
  # room  - The room which received the event
  _handleRoomEvent: (event, room, eventArgs...) ->
    #@_log "_handleRoomEvent(#{ Array::join.call(arguments, ', ') })"
    #console.log 'ROOM EVENT', arguments...
    switch event

      # a message has been sent
      when 'message'
        # we need to receive the message only if it is from someone else than the bot
        message = eventArgs[0]
        sender = @_resolveHubotUser message.fromUser
        # we need to have the bot's user
        @_resolveHubotSelfUser((err, bot) =>
          return @_log 'error', "unable to find hubot user: #{ err }" if err
          # handle the message only if it is not from the bot itself
          if "#{sender.id}" isnt "#{bot.id}"
            sender.room = room.id
            msg = new TextMessage sender, message.text, message.id
            message.private = room.oneToOne
            try
              @robot.receive msg
              @_log "handled message #{ msg.id }"
            catch err
              @_log 'error', txt = "error handling message #{ msg.id }"
              console.log txt, msg
          else
            @_log "not handling bot own message #{ message.id }"
        )

      else
        @_log "unhandled event #{ event } from room #{ room.uri }"
    # be sure to not return anything
    return


  # Private: log a message (debug by default)
  #
  # level   - The level, default to debug
  # message - The message to log
  _log: (level, message) ->
    if arguments.length is 1
      message = level
      level = 'debug'
    @robot.logger[level] "[GITTER2] #{ message }"


  # Private: register a user or update it
  #
  # userData - An object representing user data
  _resolveHubotUser: (userData) ->
    throw new Error("Invalid user data given #{ userData }") unless userData?.id and userData.id isnt 'undefined'
    userId = "#{userData.id}"
    props =
      id: userData.id
      login: userData.username
      name: if userData.displayName and userData.username then "#{ userData.displayName } (#{userData.username})" else null
      avatarUrl: userData.avatarUrlMedium
      url: userData.url
    # be sure to create the user if it does not exists
    @robot.brain.userForId userId, props
    for k, v of props when k isnt 'id' and v isnt null and v isnt undefined
      @robot.brain.data.users[userId][k] = v
    @robot.brain.userForId userId


  # Private: Get the robot user object
  _resolveHubotSelfUser: (callback) ->
    @gitter.currentUser (err, user) =>
      return callback err if err
      try
        callback null, @_resolveHubotUser user
      catch err
        callback err


exports.use = (robot) -> new GitterAdapter(robot)
