# ----------------------------------------
# IO for types begin
# ----------------------------------------
function read(io::IO, ::Type{TAMQPFrameProperties})
    TAMQPFrameProperties(
        ntoh(read(io, fieldtype(TAMQPFrameProperties, :channel))),
        ntoh(read(io, fieldtype(TAMQPFrameProperties, :payloadsize))),
    )
end

write(io::IO, p::TAMQPFrameProperties) = write(io, hton(p.channel), hton(p.payloadsize))

function read!(io::IO, b::TAMQPBodyPayload)
    read!(io, b.data)
    b
end

write(io::IO, b::TAMQPBodyPayload) = write(io, b.data)

function read(io::IO, ::Type{TAMQPShortStr})
    len = ntoh(read(io, TAMQPOctet))
    TAMQPShortStr(len, read!(io, Array(UInt8, len)))
end

function read(io::IO, ::Type{TAMQPLongStr})
    len = ntoh(read(io, TAMQPLongUInt))
    TAMQPLongStr(len, read!(io, Array(UInt8, len)))
end

write{T<:Union{TAMQPShortStr,TAMQPLongStr}}(io::IO, s::T) = write(io, hton(s.len), s.data)

function read(io::IO, ::Type{TAMQPFieldValue})
    c = read(io, Char)
    v = read(io, FieldValueIndicatorMap[c])
    TAMQPFieldValue(c, v)
end

write(io::IO, fv::TAMQPFieldValue) = write(io, fv.typ, fv.fld)

read(io::IO, ::Type{TAMQPFieldValuePair}) = TAMQPFieldValuePair(read(io, TAMQPFieldName), read(io, TAMQPFieldValue))

write(io::IO, fv::TAMQPFieldValuePair) = write(io, fv.name, fv.val)

function read(io::IO, ::Type{TAMQPFieldTable})
    len = ntoh(read(io, fieldtype(TAMQPFieldTable, :len)))
    @logmsg("read fieldtable length $(len)")
    buff = read!(io, Array(UInt8, len))
    data = TAMQPFieldValuePair[]
    iob = IOBuffer(buff)
    while !eof(iob)
        push!(data, read(iob, TAMQPFieldValuePair))
    end
    TAMQPFieldTable(len, data)
end

function write(io::IO, ft::TAMQPFieldTable)
    @logmsg("write fieldtable nfields $(length(ft.data))")
    iob = IOBuffer()
    for fv in ft.data
        write(iob, fv)
    end
    buff = takebuf_array(iob)
    len = convert(fieldtype(TAMQPFieldTable, :len), length(buff))
    @logmsg("write fieldtable length $len type: $(typeof(len))")
    l = write(io, hton(len))
    if len > 0
        l += write(io, buff)
    end
    l
end

"""
Read a generic frame. All frames have the following wire format:

0      1         3      7                  size+7     size+8
+------+---------+---------+ +-------------+ +-----------+
| type | channel | size    | |    payload  | | frame-end |
+------+---------+---------+ +-------------+ +-----------+
octet    short     long       'size' octets      octet
"""
function read(io::IO, ::Type{TAMQPGenericFrame})
    hdr = ntoh(read(io, fieldtype(TAMQPGenericFrame, :hdr)))
    @assert hdr in (1,2,3,8)
    props = read(io, fieldtype(TAMQPGenericFrame, :props))
    @logmsg("reading generic frame type:$hdr, channel:$(props.channel), payloadsize:$(props.payloadsize)")
    payload = read!(io, TAMQPBodyPayload(Array(TAMQPOctet, props.payloadsize)))
    fend = ntoh(read(io, fieldtype(TAMQPGenericFrame, :fend)))
    @assert fend == FrameEnd
    TAMQPGenericFrame(hdr, props, payload, fend)
end

write(io::IO, f::TAMQPGenericFrame) = write(io, hton(f.hdr), f.props, f.payload, f.fend)

"""
Given a generic frame, convert it to appropriate exact frame type.
"""
function narrow_frame(f::TAMQPGenericFrame)
    if f.hdr == FrameMethod
        return TAMQPMethodFrame(f)
    end
    throw(AMQPProtocolException("Unknown frame type $(f.hdr)"))
end


"""
Validate if the method frame is for the given class and method.
"""
function is_method(m::TAMQPMethodFrame, class::Symbol, method::Symbol)
    c = CLASS_MAP[m.payload.class]
    if c.name === class
        m = c.method_map[m.payload.method]
        return m.name === method
    end
    false
end

function method_key(classname::Symbol, methodname::Symbol)
    class = CLASSNAME_MAP[classname]
    method = CLASSMETHODNAME_MAP[classname,methodname]
    (FrameMethod, class.id, method.id)
end
frame_key(frame_type) = (UInt8(frame_type),)

# ----------------------------------------
# IO for types end
# ----------------------------------------

# ----------------------------------------
# Connection and Channel begin
# ----------------------------------------

const UNUSED_CHANNEL = -1
const DEFAULT_CHANNEL = 0
const DEFAULT_CHANNELMAX = 256
const DEFAULT_AUTH_PARAMS = Dict{String,Any}("MECHANISM"=>"AMQPLAIN", "LOGIN"=>"guest", "PASSWORD"=>"guest")

const CONN_STATE_CLOSED = 0
const CONN_STATE_OPENING = 1
const CONN_STATE_OPEN = 2
const CONN_STATE_CLOSING = 3
const CONN_MAX_QUEUED = typemax(Int)

abstract AbstractChannel

type Connection
    virtualhost::String
    host::String
    port::Int
    sock::Nullable{TCPSocket}

    properties::Dict{Symbol,Any}
    capabilities::Dict{String,Any}
    channelmax::TAMQPShortInt
    framemax::TAMQPLongInt
    heartbeat::TAMQPShortInt

    state::UInt8
    sendq::Channel{TAMQPGenericFrame}
    channels::Dict{TAMQPChannel, AbstractChannel}

    sender::Nullable{Task}
    receiver::Nullable{Task}
    heartbeater::Nullable{Task}

    heartbeat_time_server::Float64
    heartbeat_time_client::Float64

    function Connection(virtualhost::String="/", host::String="localhost", port::Int=AMQP_DEFAULT_PORT)
        new(virtualhost, host, port, nothing,
            Dict{Symbol,Any}(), Dict{String,Any}(), 0, 0, 0,
            CONN_STATE_CLOSED, Channel{TAMQPGenericFrame}(CONN_MAX_QUEUED), Dict{TAMQPChannel, AbstractChannel}(),
            nothing, nothing, nothing,
            0.0, 0.0)
    end
end

type MessageChannel <: AbstractChannel
    id::TAMQPChannel
    conn::Connection
    state::UInt8
    flow::Bool

    recvq::Channel{TAMQPGenericFrame}
    receiver::Nullable{Task}
    callbacks::Dict{Tuple,Tuple{Function,Any}}

    closereason::Nullable{CloseReason}

    function MessageChannel(id, conn)
        new(id, conn, CONN_STATE_CLOSED, true,
            Channel{TAMQPGenericFrame}(CONN_MAX_QUEUED), nothing, Dict{Tuple,Tuple{Function,Any}}(),
            nothing)
    end
end

sock(c::MessageChannel) = sock(c.conn)
sock(c::Connection) = get(c.sock)

isopen(c::Connection) = !isnull(c.sock) && isopen(get(c.sock))
isopen(c::MessageChannel) = isopen(c.conn) && (c.id in keys(c.conn.channels))

get_property(c::MessageChannel, s::Symbol, default) = get_property(c.conn, s, default)
get_property(c::Connection, s::Symbol, default) = get(c.properties, s, default)

send(c::MessageChannel, f) = send(c.conn, f)
send(c::Connection, f) = put!(c.sendq, TAMQPGenericFrame(f))

# ----------------------------------------
# Async message handler framework begin
# ----------------------------------------
function wait_for_state(c, states; interval=1, timeout=typemax(Int))
    t1 = time()
    while !(c.state in states)
        ((time() - t1) > timeout) && (return false)
        sleep(interval)
    end
    true
end

function connection_processor(c, name, fn)
    @logmsg("Starting $name task")
    try
        while true
            fn(c)
        end
    catch err
        reason = "$name task exiting."
        isconnclosed = !isopen(c)
        ischanclosed = isa(c, MessageChannel) && isa(err, InvalidStateException) && err.state == :closed
        if ischanclosed || isconnclosed
            reason = reason * " Connection closed"
            if c.state !== CONN_STATE_CLOSING
                reason = reason * " by peer"
                close(c, false, true)
            end
            @logmsg(reason)
        else
            reason = reason * " Unhandled exception: $err"
            @logmsg(reason)
            close(c, false, true)
            #rethrow(err)
        end
    end
end

function connection_sender(c::Connection)
    @logmsg("==> sending on conn $(c.virtualhost)")
    write(sock(c), take!(c.sendq))

    # update heartbeat time for client
    c.heartbeat_time_client = time()

    nothing
end

function connection_receiver(c::Connection)
    f = read(sock(c), TAMQPGenericFrame)

    # update heartbeat time for server
    c.heartbeat_time_server = time()

    channelid = f.props.channel
    @logmsg("<== read message on conn $(c.virtualhost) for chan $channelid")
    if !(channelid in keys(c.channels))
        @logmsg("Discarding message for unknown channel $channelid")
    end
    chan = channel(c, channelid)
    put!(chan.recvq, f)
    nothing
end

function connection_heartbeater(c::Connection)
    sleep(c.heartbeat)

    isopen(c) || throw(AMQPClientException("Connection closed"))

    now = time()
    if (now - c.heartbeat_time_client) > c.heartbeat
        send_connection_heartbeat(c)
    end

    if (now - c.heartbeat_time_server) > (2 * c.heartbeat)
        @logmsg("server heartbeat missed for $(now - c.heartbeat_time_server) seconds")
        close(c, false, false)
    end
    nothing
end

function channel_receiver(c::MessageChannel)
    f = take!(c.recvq)
    if f.hdr == FrameMethod
        m = TAMQPMethodFrame(f)
        @logmsg("<== channel: $(f.props.channel), class:$(m.payload.class), method:$(m.payload.method)")
        cbkey = (f.hdr, m.payload.class, m.payload.method)
    elseif f.hdr == FrameHeartbeat
        m = TAMQPHeartBeatFrame(f)
        @logmsg("<== channel: $(f.props.channel), heartbeat")
        cbkey = (f.hdr,)
    else
        m = f
        @logmsg("<== channel: $(f.props.channel), unhandled frame type $(f.hdr)")
        cbkey = (f.hdr,)
    end
    (cb,ctx) = get(c.callbacks, cbkey, (on_unexpected_message, nothing))
    @assert f.props.channel == c.id
    cb(c, m, ctx)
    nothing
end

clear_handlers(c::MessageChannel) = (empty!(c.callbacks); nothing)
function handle(c::MessageChannel, classname::Symbol, methodname::Symbol, cb=nothing, ctx=nothing)
    cbkey = method_key(classname, methodname)
    if cb == nothing
        delete!(c.callbacks, cbkey)
    else
        c.callbacks[cbkey] = (cb, ctx)
    end
    nothing
end
function handle(c::MessageChannel, frame_type::Integer, cb=nothing, ctx=nothing)
    cbkey = frame_key(frame_type)
    if cb == nothing
        delete!(c.callbacks, cbkey)
    else
        c.callbacks[cbkey] = (cb, ctx)
    end
    nothing
end

# ----------------------------------------
# Async message handler framework end
# ----------------------------------------

# ----------------------------------------
# Open channel / connection begin
# ----------------------------------------

function find_unused_channel(c::Connection)
    k = keys(c.channels)
    maxid = c.channelmax
    for id in 0:maxid
        if !(id in k)
            return id
        end
    end
    throw(AMQPClientException("No free channel available (max: $maxid)"))
end
channel(c::MessageChannel, id::Integer) = channel(c.conn, id)
channel(c::Connection, id::Integer) = c.channels[id]
channel(c::MessageChannel, id::Integer, create::Bool) = channel(c.conn, id, create)
function channel(c::Connection, id::Integer, create::Bool; connect_timeout=5)
    if create
        if id == UNUSED_CHANNEL
            id = find_unused_channel(c)
        elseif id in keys(c.channels)
            throw(AMQPClientException("Channel Id $id is already in use"))
        end
        chan = MessageChannel(id, c)
        chan.state = CONN_STATE_OPENING
        c.channels[chan.id] = chan

        if id != DEFAULT_CHANNEL
            # open the channel
            chan.receiver = @async connection_processor(chan, "ChannelReceiver($(chan.id))", channel_receiver)
            handle(chan, :Channel, :OpenOk, on_channel_open_ok)
            send_channel_open(chan)

            if !wait_for_state(chan, CONN_STATE_OPEN; timeout=connect_timeout)
                throw(AMQPClientException("Channel handshake failed"))
            end
        end
    else
        chan = channel(c, id)
    end
    chan
end

function channel(;virtualhost="/", host="localhost", port=AMQP_DEFAULT_PORT, auth_params=DEFAULT_AUTH_PARAMS, channelmax=DEFAULT_CHANNELMAX, framemax=0, heartbeat=0, connect_timeout=5)
    @logmsg("connecting to $(host):$(port)$(virtualhost)")
    conn = Connection(virtualhost, host, port)
    chan = channel(conn, DEFAULT_CHANNEL, true)

    # setup handler for Connection.Start
    ctx = Dict(:auth_params=>auth_params, :channelmax=>channelmax, :framemax=>framemax, :heartbeat=>heartbeat)
    handle(chan, :Connection, :Start, on_connection_start, ctx)

    # open socket and start processor tasks
    conn.sock = Nullable(connect(conn.host, conn.port))
    conn.sender = @async connection_processor(conn, "ConnectionSender", connection_sender)
    conn.receiver = @async connection_processor(conn, "ConnectionReceiver", connection_receiver)
    chan.receiver = @async connection_processor(chan, "ChannelReceiver($(chan.id))", channel_receiver)

    # initiate handshake
    conn.state = chan.state = CONN_STATE_OPENING
    write(sock(chan), ProtocolHeader)

    if !wait_for_state(conn, CONN_STATE_OPEN; timeout=connect_timeout) || !wait_for_state(chan, CONN_STATE_OPEN; timeout=connect_timeout)
        throw(AMQPClientException("Connection handshake failed"))
    end
    chan
end


# ----------------------------------------
# Open channel / connection end
# ----------------------------------------

# ----------------------------------------
# Close channel / connection begin
# ----------------------------------------

function close(chan::MessageChannel, handshake::Bool=false, by_peer::Bool=false, reply_code=ReplySuccess, reply_text="", class_id=0, method_id=0)
    (chan.state == CONN_STATE_CLOSED) && (return nothing)

    conn = chan.conn

    if chan.id == DEFAULT_CHANNEL
        # default channel represents the connection
        close(conn, handshake, by_peer, reply_code, reply_text, class_id, method_id)
    elseif chan.state != CONN_STATE_CLOSING
        # send handshake if needed and when called the first time
        chan.state = CONN_STATE_CLOSING
        if handshake && !by_peer
            send_channel_close(chan, reply_code, reply_text, class_id, method_id)
        end
    end

    # release resources when closed by peer or when closing abruptly
    if !handshake || by_peer
        close(chan.recvq)
        chan.receiver = nothing
        chan.callbacks = Dict{Tuple,Tuple{Function,Any}}()
        delete!(chan.conn.channels, chan.id)
        chan.state = CONN_STATE_CLOSED
    end
    nothing
end

function close(conn::Connection, handshake::Bool=false, by_peer::Bool=false, reply_code=ReplySuccess, reply_text="", class_id=0, method_id=0)
    (conn.state == CONN_STATE_CLOSED) && (return nothing)

    # send handshake if needed and when called the first time
    if conn.state != CONN_STATE_CLOSING
        conn.state = CONN_STATE_CLOSING

        # close all other open channels
        for open_channel in collect(values(conn.channels))
            if open_channel.id != DEFAULT_CHANNEL
                close(open_channel, false, by_peer)
            end
        end

        # send handshake if needed
        if handshake && !by_peer
            send_connection_close(conn, reply_code, reply_text, class_id, method_id)
        end
    end

    if !handshake || by_peer
        # close socket
        close(get(conn.sock))
        conn.sock = nothing

        # reset all members
        conn.properties = Dict{Symbol,Any}()
        conn.capabilities = Dict{String,Any}()
        conn.channelmax = 0
        conn.framemax = 0
        conn.heartbeat = 0

        # close and reset the sendq channel
        close(conn.sendq)
        conn.sendq = Channel{TAMQPGenericFrame}(CONN_MAX_QUEUED)

        # reset the tasks
        conn.sender = nothing
        conn.receiver = nothing
        conn.heartbeater = nothing
        conn.state = CONN_STATE_CLOSED
    end
    nothing
end

# ----------------------------------------
# Close channel / connection end
# ----------------------------------------

# ----------------------------------------
# Connection and Channel end
# ----------------------------------------

# ----------------------------------------
# send and recv for methods begin
# ----------------------------------------

function on_unexpected_message(c::MessageChannel, m::TAMQPMethodFrame, ctx)
    @logmsg("Unexpected message on channel $(c.id): class:$(m.payload.class), method:$(m.payload.method)")
    nothing
end

function on_unexpected_message(c::MessageChannel, f, ctx)
    @logmsg("Unexpected message on channel $(c.id): frame type: $(f.hdr)")
    nothing
end

function _send_close_ok(context_class::Symbol, chan::MessageChannel)
    props = TAMQPFrameProperties(chan.id,0)
    payload = TAMQPMethodPayload(context_class, :CloseOk, ())
    @logmsg("sending $context_class CloseOk")
    send(chan, TAMQPMethodFrame(props, payload))
    nothing
end

function _on_close_ok(context_class::Symbol, chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    @assert is_method(m, context_class, :CloseOk)
    close(chan, false, true)
    nothing
end

function _send_close(context_class::Symbol, chan::MessageChannel, reply_code=ReplySuccess, reply_text="", class_id=0, method_id=0)
    chan.closereason = CloseReason(TAMQPReplyCode(reply_code), TAMQPReplyText(reply_text), TAMQPClassId(class_id), TAMQPMethodId(method_id))
    if context_class === :Channel && chan.id == DEFAULT_CHANNEL
        @logmsg("closing channel 0 is equivalent to closing the connection!")
        context_class = :Connection
    end

    _send_close(context_class, chan.conn, reply_code, reply_text, class_id, method_id, chan.id)
end

function _send_close(context_class::Symbol, conn::Connection, reply_code=ReplySuccess, reply_text="", class_id=0, method_id=0, chan_id=0)
    props = TAMQPFrameProperties(chan_id,0)
    payload = TAMQPMethodPayload(context_class, :Close, (TAMQPReplyCode(reply_code), TAMQPReplyText(reply_text), TAMQPClassId(class_id), TAMQPMethodId(method_id)))
    # CloseOk is always handled on channels/connections
    @logmsg("sending $context_class Close")
    send(conn, TAMQPMethodFrame(props, payload))
    nothing
end

send_connection_close_ok(chan::MessageChannel) = _send_close_ok(:Connection, chan)
on_connection_close_ok(chan::MessageChannel, m::TAMQPMethodFrame, ctx) = _on_close_ok(:Connection, chan, m, ctx)
function on_connection_close(chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    @assert is_method(m, :Connection, :Close)
    @assert chan.id == DEFAULT_CHANNEL
    chan.closereason = CloseReason(m.payload.fields[1].second, m.payload.fields[2].second, m.payload.fields[3].second, m.payload.fields[4].second)
    send_connection_close_ok(chan)
    t1 = time()
    while isready(chan.conn.sendq) && ((time() - t1) < 5)
        yield() # wait 5 seconds (arbirtary) for the message to get sent
    end
    close(chan, false, true)
end
function on_channel_close(chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    @assert is_method(m, :Channel, :Close)
    @assert chan.id != DEFAULT_CHANNEL
    chan.closereason = CloseReason(m.payload.fields[1].second, m.payload.fields[2].second, m.payload.fields[3].second, m.payload.fields[4].second)
    send_channel_close_ok(chan)
    close(chan, false, true)
end

send_connection_close(chan::MessageChannel, reply_code=ReplySuccess, reply_text="", class_id=0, method_id=0) = _send_close(:Connection, chan, reply_code, reply_text, class_id, method_id)
send_connection_close(conn::Connection, reply_code=ReplySuccess, reply_text="", class_id=0, method_id=0) = _send_close(:Connection, conn, reply_code, reply_text, class_id, method_id)

send_channel_close_ok(chan::MessageChannel) = _send_close_ok(:Channel, chan)
on_channel_close_ok(chan::MessageChannel, m::TAMQPMethodFrame, ctx) = _on_close_ok(:Channel, chan, m, ctx)
send_channel_close(chan::MessageChannel, reply_code=ReplySuccess, reply_text="", class_id=0, method_id=0) = _send_close(:Channel, chan, reply_code, reply_text, class_id, method_id)

function on_connection_start(chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    @assert is_method(m, :Connection, :Start)
    @assert chan.id == DEFAULT_CHANNEL
    conn = chan.conn

    # setup server properties and capabilities
    merge!(conn.properties, Dict{Symbol,Any}(m.payload.fields...))
    server_props = convert(Dict{String,Any}, get_property(chan, :ServerProperties, Dict{String,Any}()))
    if "capabilities" in keys(server_props)
        for f in server_props["capabilities"].fld.data
            conn.capabilities[String(f.name)] = f.val.fld
        end
    end

    handle(chan, :Connection, :Start)
    auth_params = ctx[:auth_params]
    delete!(ctx, :auth_params)  # we cont need auth params any more
    handle(chan, :Connection, :Tune, on_connection_tune, ctx)
    send_connection_start_ok(chan, auth_params)
    nothing
end

function send_connection_start_ok(chan::MessageChannel, auth_params::Dict{String,Any}=Dict{String,Any}())
    conn = chan.conn

    # set up client_props
    client_props = copy(CLIENT_IDENTIFICATION)
    client_cap = client_props["capabilities"]
    server_cap = conn.capabilities
    @logmsg("server capabilities: $server_cap")
    if "consumer_cancel_notify" in keys(server_cap)
        client_cap["consumer_cancel_notify"] = server_cap["consumer_cancel_notify"]
    end
    if "connection.blocked" in keys(server_cap)
        client_cap["connection.blocked"] = server_cap["connection.blocked"]
    end
    @logmsg("client_props: $(client_props)")

    # assert that auth mechanism is supported
    mechanism = auth_params["MECHANISM"]
    mechanisms = split(get_property(chan, :Mechanisms, ""), ' ')
    @logmsg("mechanism: $mechanism, supported mechanisms: $(mechanisms)")
    @assert mechanism in mechanisms

    # set up locale
    client_locale = locale()
    if isempty(client_locale)
        # pick up one of the server locales
        locales = split(get_property(chan, :Locales, ""), ' ')
        @logmsg("supported locales: $(locales)")
        client_locale = locales[1]
    end
    @logmsg("client_locale: $(client_locale)")

    # respond to login
    auth_resp = AUTH_PROVIDERS[mechanism](auth_params)
    @logmsg("auth_resp: $(auth_resp)")

    props = TAMQPFrameProperties(chan.id,0)
    payload = TAMQPMethodPayload(:Connection, :StartOk, (client_props, mechanism, auth_resp, client_locale))
    @logmsg("sending Connection StartOk")
    send(chan, TAMQPMethodFrame(props, payload))
    nothing
end

function on_connection_tune(chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    @assert is_method(m, :Connection, :Tune)
    @assert chan.id == DEFAULT_CHANNEL
    conn = chan.conn

    conn.channelmax = m.payload.fields[1].second
    conn.framemax = m.payload.fields[2].second
    conn.heartbeat = m.payload.fields[3].second
    handle(chan, FrameHeartbeat, on_connection_heartbeat)
    send_connection_tune_ok(chan, ctx[:channelmax], ctx[:framemax], ctx[:heartbeat])
    handle(chan, :Connection, :TuneOk)
    handle(chan, :Connection, :OpenOk, on_connection_open_ok, ctx)
    send_connection_open(chan)
    nothing
end

function send_connection_tune_ok(chan::MessageChannel, channelmax=0, framemax=0, heartbeat=0)
    conn = chan.conn

    # set channelmax and framemax
    (channelmax > 0) && (conn.channelmax = channelmax)
    (framemax > 0) && (conn.framemax = framemax)

    # negotiate heartbeat (min of what expected by both parties)
    if heartbeat > 0 && conn.heartbeat > 0
        conn.heartbeat = min(conn.heartbeat, heartbeat)
    else
        conn.heartbeat = max(conn.heartbeat, heartbeat)
    end

    props = TAMQPFrameProperties(chan.id,0)
    @logmsg("channelmax: $(conn.channelmax), framemax: $(conn.framemax), heartbeat: $(conn.heartbeat)")
    payload = TAMQPMethodPayload(:Connection, :TuneOk, (conn.channelmax, conn.framemax, conn.heartbeat))
    @logmsg("sending Connection TuneOk")
    send(chan, TAMQPMethodFrame(props, payload))

    # start heartbeat timer
    conn.heartbeater = @async connection_processor(conn, "HeartBeater", connection_heartbeater)
    nothing
end

function send_connection_open(chan::MessageChannel)
    props = TAMQPFrameProperties(chan.id,0)
    payload = TAMQPMethodPayload(:Connection, :Open, (chan.conn.virtualhost, "", false))
    @logmsg("sending Connection Open")
    send(chan, TAMQPMethodFrame(props, payload))
    nothing
end

function on_connection_open_ok(chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    @assert is_method(m, :Connection, :OpenOk)
    @assert chan.id == DEFAULT_CHANNEL
    conn = chan.conn

    conn.state = CONN_STATE_OPEN
    chan.state = CONN_STATE_OPEN

    handle(chan, :Connection, :Close, on_connection_close, ctx)
    handle(chan, :Connection, :CloseOk, on_connection_close_ok, ctx)

    nothing
end

function on_connection_heartbeat(chan::MessageChannel, h::TAMQPHeartBeatFrame, ctx)
    nothing
end

function send_connection_heartbeat(conn::Connection)
    send(conn, TAMQPHeartBeatFrame())
    nothing
end

function send_channel_open(chan::MessageChannel)
    props = TAMQPFrameProperties(chan.id,0)
    payload = TAMQPMethodPayload(:Channel, :Open, ("",))
    @logmsg("sending Channel Open")
    send(chan, TAMQPMethodFrame(props, payload))
    nothing
end

function on_channel_open_ok(chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    chan.state = CONN_STATE_OPEN
    handle(chan, :Channel, :Flow, on_channel_flow, :Flow)
    handle(chan, :Channel, :FlowOk, on_channel_flow, :FlowOk)
    handle(chan, :Channel, :Close, on_channel_close)
    handle(chan, :Channel, :CloseOk, on_channel_close_ok)
    nothing
end

function send_channel_flow(chan::MessageChannel, flow::Bool)
    props = TAMQPFrameProperties(chan.id,0)
    payload = TAMQPMethodPayload(:Channel, :Flow, (flow,))
    @logmsg("sending Channel Flow")
    send(chan, TAMQPMethodFrame(props, payload))
    nothing
end

function on_channel_flow(chan::MessageChannel, m::TAMQPMethodFrame, ctx)
    @assert is_method(m, :Channel, ctx)
    chan.flow = m.payload.fields[1].second
    @logmsg("channel $(chan.id) flow is now $(chan.flow)")
    nothing
end

# ----------------------------------------
# send and recv for methods end
# ----------------------------------------