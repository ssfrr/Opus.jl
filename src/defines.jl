# Opus error codes
const OPUS_OK               =  0
const OPUS_BAD_ARG          = -1
const OPUS_BUFFER_TOO_SMALL = -2
const OPUS_INTERNAL_ERROR   = -3
const OPUS_INVALID_PACKET   = -4
const OPUS_UNIMPLEMENTED    = -5
const OPUS_INVALID_STATE    = -6
const OPUS_ALLOC_FAIL       = -7

const OPUS_ERROR_MESSAGE_STRS = Dict(
    0  => "No Error",
    -1 => "Bad Argument",
    -2 => "Buffer Too Small",
    -3 => "Internal Error",
    -4 => "Invalid Packet",
    -5 => "Unimplemented",
    -6 => "Invalid State",
    -7 => "Allocation Failure"
)

const OPUS_APPLICATION_VOIP                = 2048
const OPUS_APPLICATION_AUDIO               = 2049
const OPUS_APPLICATION_RESTRICTED_LOWDELAY = 2051

struct OpusHead
    # Should always be equal to one
    version::UInt8
    # Number of channels, must be greater than zero
    channels::UInt8
    # This is the number of samples (at 48 kHz) to discard from the decoder
    # output when starting playback, and also the number to subtract from a
    # page's granule position to calculate its PCM sample position.
    # NOTE: This is currently completely ignored in Opus.jl
    preskip::UInt16
    # Samplerate of input stream (Let's face it, it's always 48 KHz)
    samplerate::Int32
    # Output gain that should be applied
    output_gain::UInt16
    # Channel mapping family
    channel_map_family::UInt8
    # number of total input streams in a multistream opus stream
    stream_count::UInt8
    # number of streams that should be decoded as stereo
    coupled_count::UInt8
    # this table specifies for each output channel, which input channel should
    # be mapped into it. For instance a table of [0, 1, 2, 2] would decode 3
    # encoded channels into 4 output channels, with the third channel repeated
    # into the third and fourth output channels
    channel_map_table::Vector{UInt8}
end

OpusHead() = OpusHead(1, 1, 312, 48000, 0, 0, 0, 0, UInt8[])
OpusHead(samplerate, channels) = OpusHead(1, channels, 312, samplerate, 0, 0, 0, 0, UInt8[])

# this header is technically part of the Ogg-Opus spec:
# https://tools.ietf.org/html/draft-ietf-codec-oggopus-14
# it defines the necessary header for an Opus stream embedded within an Ogg
# container stream

function OpusHead(io::IO)
    magic = read(io, 8)
    if magic != b"OpusHead"
        error("Input packet is not an \"OpusHead\"!, magic is $(magic)")
    end
    version = read(io, UInt8)
    channels = read(io, UInt8)
    preskip = ltoh(read(io, UInt16))
    samplerate = ltoh(read(io, UInt32))
    output_gain = ltoh(read(io, UInt16))
    channel_map_family = read(io, UInt8)
    if channel_map_family == 0
        stream_count = 1
        coupled_count = channels-1
        channel_map_table = UInt8[]
    else
        stream_count = read(io, UInt8)
        coupled_count = read(io, UInt8)
        channel_map_table = read(io, channels)
    end
    return OpusHead(version, channels, preskip, samplerate, output_gain,
                    channel_map_family, stream_count, coupled_count,
                    channel_map_table)
end
OpusHead(data::Vector{UInt8}) = OpusHead(IOBuffer(data))

function write(io::IO, x::OpusHead)
    for val in (b"OpusHead",
                x.version,
                x.channels,
                x.preskip,
                x.samplerate,
                x.output_gain,
                x.channel_map_family)
        write(io, val)
    end
    if x.channel_map_family != 0
        for val in (x.stream_count,
                    x.coupled_count,
                    x.channel_map_table)
            write(io, val)
        end
    end
end

function convert(::Type{Vector{UInt8}}, x::OpusHead)
    io = IOBuffer()
    write(io, x)
    seekstart(io)
    return read(io)
end

function show(io::IO, x::OpusHead)
    write(io, "OpusHead packet ($(x.samplerate)Hz, $(x.channels) channels)")
end


mutable struct OpusTags
    vendor_string::AbstractString
    tags::Vector{AbstractString}
end
OpusTags() = OpusTags("Opus.jl", AbstractString["encoder=Opus.jl"])

function read_opus_tag(io::IO)
    # First, read in a length
    len = read(io, UInt32)

    # Next, read the string
    return String(read(io, len))
end

function write_opus_tag(io::IO, tag::AbstractString)
    # First, write out the length
    write(io, UInt32(length(tag)))

    # Next, write out the tag itself
    write(io, tag)
end

function OpusTags(io::IO)
    magic = read(io, 8)
    if magic != b"OpusTags"
        error("Input packet is not an OpusTags!, magic is $(magic)")
    end
    # First, read the vendor string
    vendor_string = read_opus_tag(io)

    # Next, read how many tags we've got
    num_tags = read(io, UInt32)

    # Read all the tags in, one after another
    tags = [read_opus_tag(io) for idx in 1:num_tags]

    return OpusTags(vendor_string, tags)
end
OpusTags(data::Vector{UInt8}) = OpusTags(IOBuffer(data))

function write(io::IO, x::OpusTags)
    write(io, b"OpusTags")
    write_opus_tag(io, x.vendor_string)

    write(io, UInt32(length(x.tags)))
    for tagidx = 1:length(x.tags)
        write_opus_tag(io, x.tags[tagidx])
    end
end

function convert(::Type{Vector{UInt8}}, x::OpusTags)
    io = IOBuffer()
    write(io, x)
    seekstart(io)
    return read(io)
end

function show(io::IO, x::OpusTags)
    write(io, "OpusTags packet\n")
    write(io, "  Vendor: $(x.vendor_string)\n")
    write(io, "  Tags:")
    for tag in x.tags
        write(io, "\n")
        write(io, "    $tag")
    end
end


function is_header_packet(packet::Vector{UInt8})
    # Check if it's an OpusHead or OpusTags packet
    if length(packet) > 8
        magic = packet[1:8]
        if magic == b"OpusHead" || magic == b"OpusTags"
            return true
        end
    end

    return false
end
