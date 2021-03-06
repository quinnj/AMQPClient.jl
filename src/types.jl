const LiteralAMQP = UInt8[65, 77, 81, 80] # "AMQP"
const ProtocolId = UInt8(0)
const ProtocolVersion = UInt8[0, 9, 1]

const ProtocolHeader = vcat(LiteralAMQP, ProtocolId, ProtocolVersion)

const ContentWeight = 0x0000
const FrameEnd = 0xCE
const HeartBeat = UInt8[8, 0, 0, FrameEnd]

@compat abstract type TAMQPLengthPrefixed end

#const TAMQPBit                  = UInt8
const TAMQPBool                 = UInt8 # 0 = FALSE, else TRUE
const TAMQPScale                = UInt8 # number of decimal digits
const TAMQPOctet                = UInt8
const TAMQPShortShortInt        = UInt8
const TAMQPShortShortUInt       = UInt8
const TAMQPShortInt             = Int16
const TAMQPShortUInt            = UInt16
const TAMQPLongInt              = Int32
const TAMQPLongUInt             = UInt32
const TAMQPLongLongInt          = Int64
const TAMQPLongLongUInt         = UInt64
const TAMQPFloat                = Float32
const TAMQPDouble               = Float64
const TAMQPTimeStamp            = TAMQPLongLongUInt

immutable TAMQPBit
    val::UInt8
end

function TAMQPBit(b::TAMQPBit, pos::Int)
    TAMQPBit((b.val >> (pos-1)) & 0x1)
end

function TAMQPBit(b::TAMQPBit, setbit::TAMQPBit, pos::Int)
    TAMQPBit(b.val | (setbit.val << (pos-1)))
end

immutable TAMQPDecimalValue
    scale::TAMQPScale
    val::TAMQPLongUInt
end

immutable TAMQPShortStr <: TAMQPLengthPrefixed
    len::TAMQPOctet
    data::Vector{Int8}
end

immutable TAMQPLongStr <: TAMQPLengthPrefixed
    len::TAMQPLongUInt
    data::Vector{UInt8}
end

const TAMQPFieldName = TAMQPShortStr
const TAMQPFV = Union{Real, TAMQPDecimalValue, TAMQPLengthPrefixed, Void}

immutable TAMQPFieldValue{T <: TAMQPFV}
    typ::Char  # as in FieldValueIndicatorMap
    fld::T
end

immutable TAMQPFieldValuePair{T <: TAMQPFV}
    name::TAMQPFieldName
    val::TAMQPFieldValue{T}
end

immutable TAMQPFieldArray <: TAMQPLengthPrefixed
    len::TAMQPLongInt
    data::Vector{TAMQPFieldValue}
end

immutable TAMQPFieldTable <: TAMQPLengthPrefixed
    len::TAMQPLongUInt
    data::Vector{TAMQPFieldValuePair}
end

const TAMQPField = Union{TAMQPBit, Integer, TAMQPShortStr, TAMQPLongStr, TAMQPFieldTable}

const FieldValueIndicatorMap = Dict{Char,DataType}(
    't' => TAMQPBool,
    'b' => TAMQPShortShortInt,
    'B' => TAMQPShortShortUInt,
    'U' => TAMQPShortInt,
    'u' => TAMQPShortUInt,
    'I' => TAMQPLongInt,
    'i' => TAMQPLongUInt,
    'L' => TAMQPLongLongInt,
    'l' => TAMQPLongLongUInt,
    'f' => TAMQPFloat,
    'd' => TAMQPDouble,
    'D' => TAMQPDecimalValue,
    's' => TAMQPShortUInt,
    'S' => TAMQPLongStr,
    'x' => TAMQPLongStr,
    'A' => TAMQPFieldArray,
    'T' => TAMQPTimeStamp,
    'F' => TAMQPFieldTable,
    'V' => Void
)

const FieldIndicatorMap = Dict{DataType,Char}(v=>n for (n,v) in FieldValueIndicatorMap)

const TAMQPChannel          = TAMQPShortUInt
const TAMQPPayloadSize      = TAMQPLongUInt
const TAMQPContentBodySize  = TAMQPLongLongUInt
const TAMQPClassId          = UInt16
const TAMQPMethodId         = UInt16
const TAMQPContentClass     = TAMQPClassId

immutable TAMQPFrameProperties
    channel::TAMQPChannel
    payloadsize::TAMQPPayloadSize
end

immutable TAMQPPropertyFlags
    flags::UInt16
    nextval::Nullable{TAMQPPropertyFlags}
end
TAMQPPropertyFlags(flags::UInt16) = TAMQPPropertyFlags(flags, nothing)

immutable TAMQPBodyPayload
    # TODO: may be better to allow sub arrays, for efficient writing of large messages
    data::Vector{TAMQPOctet}
end

immutable TAMQPMethodPayload
    class::TAMQPClassId
    method::TAMQPMethodId
    fields::Vector{Pair{Symbol,TAMQPField}}

    TAMQPMethodPayload(p::TAMQPBodyPayload) = TAMQPMethodPayload(p.data)
    TAMQPMethodPayload(b::Vector{TAMQPOctet}) = TAMQPMethodPayload(IOBuffer(b))
    function TAMQPMethodPayload(io)
        class = ntoh(read(io, TAMQPClassId))
        method = ntoh(read(io, TAMQPMethodId))
        args = methodargs(class, method)
        fields = Array{Pair{Symbol,TAMQPField}}(length(args))
        @logmsg("reading method payload class:$class, method:$method, nargs:$(length(args))")
        bitpos = 0
        bitval = TAMQPBit(0)
        for idx in 1:length(fields)
            fld = args[idx]
            @logmsg("reading field $(fld.first) of type $(fld.second)")
            if fld.second === TAMQPBit
                bitpos += 1
                (bitpos == 1) && (bitval = read(io, fld.second))
                v = TAMQPBit(bitval, bitpos)
                (bitpos == 8) && (bitpos == 0)
            else
                bitpos = 0
                v = read(io, fld.second)
            end
            issubtype(fld.second, Integer) && (v = ntoh(v))
            fields[idx] = Pair{Symbol,TAMQPField}(fld.first, v)
        end
        new(class, method, fields)
    end
    function TAMQPMethodPayload(class_name::Symbol, method_name::Symbol, fldvals)
        class = CLASSNAME_MAP[class_name]
        method = CLASSMETHODNAME_MAP[(class_name,method_name)]
        fields = Pair{Symbol,TAMQPField}[]
        for idx in 1:length(method.args)
            (argname,argtype) = method.args[idx]
            push!(fields, Pair{Symbol,TAMQPField}(argname, convert(argtype, fldvals[idx])))
        end
        new(class.id, method.id, fields)
    end
end

immutable TAMQPHeaderPayload
    class::TAMQPContentClass
    weight::UInt16  # must be ContentWeight
    bodysize::TAMQPContentBodySize
    propflags::TAMQPPropertyFlags
    proplist::Dict{Symbol,TAMQPField}

    TAMQPHeaderPayload(p::TAMQPBodyPayload) = TAMQPHeaderPayload(p.data)
    TAMQPHeaderPayload(b::Vector{TAMQPOctet}) = TAMQPHeaderPayload(IOBuffer(b))
    function TAMQPHeaderPayload(io)
        class = ntoh(read(io, TAMQPClassId))
        wt = ntoh(read(io, UInt16))
        @assert wt === ContentWeight
        bodysize = ntoh(read(io, TAMQPContentBodySize))
        propflags = TAMQPPropertyFlags(ntoh(read(io, UInt16)))
        proplist = Dict{Symbol,TAMQPField}()
   
        flags = propflags.flags 
        for prop in SORTED_PROPERTIES
            if (flags & prop.mask) > 0x0000
                proplist[prop.name] = read(io, prop.typ)
            end
        end
        new(class, ContentWeight, bodysize, propflags, proplist)
    end
    function TAMQPHeaderPayload(class::TAMQPContentClass, message)
        bodysize = length(message.data)
        flags = 0x0000
        for name in keys(message.properties)
            flags = flags | PROPERTIES[name].mask
        end
        new(class, ContentWeight, bodysize, TAMQPPropertyFlags(flags), message.properties)
    end
end

# Generic frame, used to read any frame
immutable TAMQPGenericFrame
    hdr::UInt8
    props::TAMQPFrameProperties
    payload::TAMQPBodyPayload
    fend::UInt8 # must be FrameEnd
end

# Type = 1, "METHOD": method frame
immutable TAMQPMethodFrame
    props::TAMQPFrameProperties
    payload::TAMQPMethodPayload
end

function TAMQPMethodFrame(f::TAMQPGenericFrame)
    @logmsg("Frame Conversion: generic => method")
    @assert f.hdr == FrameMethod
    TAMQPMethodFrame(f.props, TAMQPMethodPayload(f.payload))
end

function TAMQPGenericFrame(f::TAMQPMethodFrame)
    @logmsg("Frame Conversion method => generic")
    iob = IOBuffer()
    methpayload = f.payload
    write(iob, hton(methpayload.class))
    write(iob, hton(methpayload.method))
    bitpos = 0
    bitval = TAMQPBit(0)
    for (n,v) in methpayload.fields
        if isa(v, TAMQPBit)
            bitpos += 1
            bitval = TAMQPBit(bitval, v, bitpos)
            if bitpos == 8
                write(iob, bitval)
                bitpos = 0
                bitval = TAMQPBit(0)
            end
        else
            if bitpos > 0
                write(iob, bitval)
                bitpos = 0
                bitval = TAMQPBit(0)
            end
            issubtype(typeof(v), Integer) && (v = hton(v))
            write(iob, v)
        end
    end
    if bitpos > 0
        write(iob, bitval)
    end
    bodypayload = TAMQPBodyPayload(take!(iob))
    TAMQPGenericFrame(FrameMethod, TAMQPFrameProperties(f.props.channel, length(bodypayload.data)), bodypayload, FrameEnd)
end

# Type = 2, "HEADER": content header frame.
immutable TAMQPContentHeaderFrame
    props::TAMQPFrameProperties
    hdrpayload::TAMQPHeaderPayload
end

function TAMQPContentHeaderFrame(f::TAMQPGenericFrame)
    @logmsg("Frame Conversion: generic => contentheader")
    @assert f.hdr == FrameHeader
    TAMQPContentHeaderFrame(f.props, TAMQPHeaderPayload(f.payload))
end

function TAMQPGenericFrame(f::TAMQPContentHeaderFrame)
    @logmsg("Frame Conversion contentheader => generic")
    iob = IOBuffer()
    hdrpayload = f.hdrpayload
    propflags = hdrpayload.propflags
    proplist = hdrpayload.proplist

    write(iob, hton(hdrpayload.class))
    write(iob, hton(hdrpayload.weight))
    write(iob, hton(hdrpayload.bodysize))
    write(iob, hton(propflags.flags))

    flags = propflags.flags
    for prop in SORTED_PROPERTIES
        if (flags & prop.mask) > 0x0000
            write(iob, proplist[prop.name])
        end
    end
    bodypayload = TAMQPBodyPayload(take!(iob))
    TAMQPGenericFrame(FrameHeader, TAMQPFrameProperties(f.props.channel, length(bodypayload.data)), bodypayload, FrameEnd)
end

# Type = 3, "BODY": content body frame.
immutable TAMQPContentBodyFrame
    props::TAMQPFrameProperties
    payload::TAMQPBodyPayload
end

function TAMQPContentBodyFrame(f::TAMQPGenericFrame)
    @logmsg("Frame Conversion: generic => contentbody")
    @assert f.hdr == FrameBody
    TAMQPContentBodyFrame(f.props, f.payload)
end

function TAMQPGenericFrame(f::TAMQPContentBodyFrame)
    @logmsg("Frame Conversion contentbody => generic")
    TAMQPGenericFrame(FrameBody, TAMQPFrameProperties(f.props.channel, length(f.payload.data)), f.payload, FrameEnd)
end

# Type = 4, "HEARTBEAT": heartbeat frame.
immutable TAMQPHeartBeatFrame
end

function TAMQPHeartBeatFrame(f::TAMQPGenericFrame)
    @assert f.hdr == FrameHeartbeat
    TAMQPHeartBeatFrame()
end

function TAMQPGenericFrame(f::TAMQPHeartBeatFrame)
    @logmsg("Frame Conversion heartbeat => generic")
    TAMQPGenericFrame(FrameHeartbeat, TAMQPFrameProperties(DEFAULT_CHANNEL, 0), TAMQPBodyPayload(TAMQPOctet[]), FrameEnd)
end

immutable TAMQPContent
    hdr::TAMQPContentHeaderFrame
    body::Vector{TAMQPContentBodyFrame}
end

immutable TAMQPMethod
    frame::TAMQPMethodFrame
    content::Nullable{TAMQPContent}
end

# Exceptions
type AMQPProtocolException <: Exception
    msg::String
end

type AMQPClientException <: Exception
    msg::String
end

# Spec code gen types
immutable MethodSpec
    id::Int
    name::Symbol
    respname::Symbol
    args::Vector{Pair{Symbol,DataType}}
end

immutable ClassSpec
    id::Int
    name::Symbol 
    method_map::Dict{Int,MethodSpec}
end

immutable CloseReason
    code::Int16
    msg::TAMQPShortStr
    classid::TAMQPClassId
    methodid::TAMQPMethodId
end

# Utility Methods for Types
method(classid::TAMQPClassId, methodid::TAMQPMethodId) = CLASS_MAP[classid].method_map[methodid]
methodargs(classid::TAMQPClassId, methodid::TAMQPMethodId) = method(classid, methodid).args
function displayname(classid::TAMQPClassId, methodid::TAMQPMethodId)
    c = CLASS_MAP[classid]
    m = c.method_map[methodid]
    "$(c.name).$(m.name)"
end
