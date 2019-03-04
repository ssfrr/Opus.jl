using SampledSignals

mutable struct OpusIter{T, S, N}
    packetsource::T
    iterstate::S
    decoder::Ptr{Cvoid}
    header::OpusHead
    tags::OpusTags
    buf::Vector{Float32}
    bufoffset::Int
end

const allowed_samplerates = (8000, 12000, 16000, 24000, 48000)

function OpusIter(packetsource, samplerate=48000)
    if samplerate ∉ allowed_samplerates
        throw(ArgumentError("Samplerate must be $(join(allowed_samplerates, ", ", ", or ")). Got $samplerate"))
    end
    iter = iterate(packetsource)
    iter === nothing && throw(ErrorException("Reached end of packet stream without a header packet"))
    packet, iterstate = iter
    header = OpusHead(packet)
    iter = iterate(packetsource, iterstate)
    packet === nothing && throw(ErrorException("Reached end of packet stream without a tags packet"))
    packet, iterstate = iter
    tags = OpusTags(packet)

    errorptr = Ref{Cint}(0);

    # Create new decoder object with the given samplerate and channel info
    decoder = ccall((:opus_multistream_decoder_create, libopus), Ptr{Cvoid},
                    (Int32, Cint, Cint, Cint, Ref{UInt8}, Ref{Cint}),
                    samplerate, header.channels, header.stream_count,
                    header.coupled_count, header.channel_map_table, errorptr)
    err = errorptr[]
    if err != OPUS_OK
        error("opus_multistream_decoder_create() failed: $(OPUS_ERROR_MESSAGE_STRS[err])")
    end

    OpusIter{typeof(packetsource), typeof(iterstate), Int(header.channels)}(
            packetsource, iterstate, decoder, header, tags, Float32[], 0)
end

function Base.close(dec::OpusIter)
    if dec.decoder != C_NULL
        ccall((:opus_multistream_decoder_destroy,libopus), Cvoid, (Ptr{Cvoid},), dec.decoder)
        dec.decoder = C_NULL
    else
        @warn "Opus decoder closed more than once"
    end
end

@inline function OpusIter(fn::Function, args...)
    opus = OpusIter(args...)
    try
        fn(opus)
    finally
        close(opus)
    end
end

function Base.iterate(opus::OpusIter, state=nothing)
    @assert opus.bufoffset <= length(opus.buf)
    if opus.bufoffset == length(opus.buf)
        # we've read everything from the buffer, reload it from the packet
        # iterator
        iter = iterate(opus.packetsource, opus.iterstate)
        iter === nothing && return nothing
        packet, opus.iterstate = iter
        packet_frames = get_nb_samples(packet, samplerate(opus))
        packet_samples = packet_frames * nchannels(opus)
        # resize our buffer if necessary
        if length(opus.buf) != packet_samples
            resize!(opus.buf, packet_samples)
        end
        # TODO: figure out whether we need to be handling the `decode_fec` argument
        num_samples = ccall((:opus_multistream_decode_float, libopus), Cint,
                            (Ptr{Cvoid}, Ref{UInt8}, Int32, Ref{Float32}, Cint, Cint),
                            opus.decoder, packet, length(packet),
                            opus.buf, packet_frames, 0)
        if num_samples < 0
            error("opus_decode_float() failed: $(OPUS_ERROR_MESSAGE_STRS[num_samples])")
        end

        opus.bufoffset = 0
    end

    # TODO is it faster to reinterpret rather than copying into the tuple?
    outframe = ntuple(i->opus.buf[opus.bufoffset+i], nchannels(opus))
    opus.bufoffset += nchannels(opus)

    (outframe, nothing)
end

SampledSignals.samplerate(dec::OpusIter) = Int(dec.header.samplerate)
SampledSignals.nchannels(dec::OpusIter{T, S, N}) where {T, S, N} = N
Base.IteratorSize(::Type{<:OpusIter}) = Base.SizeUnknown()
Base.IteratorEltype(::Type{<:OpusIter}) = Base.HasEltype()
Base.eltype(::Type{OpusIter{T, S, N}}) where {T, S, N} = NTuple{N, Float32}

function get_nb_samples(data, fs)
    num_samples = ccall((:opus_packet_get_nb_samples, libopus), Cint,
                        (Ptr{UInt8}, Int32, Int32),
                        data, length(data), fs)
    if num_samples < 0
        error("opus_packet_get_nb_samples() failed: $(OPUS_ERROR_MESSAGE_STRS[num_samples])")
    end
    return num_samples
end

# """
# Returns (audio, fs) unless the ogg file has no opus streams
# """
# function load(fio::IO)
#     audio = nothing
#     packets = Ogg.load(fio)
#     for serial in keys(packets)
#         opus_head = OpusHead()
#         opus_tags = OpusTags()
#         try
#             # Find the first stream that is Opus and decode it
#             opus_head = OpusHead(packets[serial][1])
#             opus_tags = OpusTags(packets[serial][2])
#         # TODO: throw a more specific exception. Catching all exceptions here
#         # makes things hard to debug if there's a problem (or Julia syntax changes)
#         catch
#             continue
#         end
#         dec = Opus.OpusDecoder(48000, opus_head.channels)
#         audio = decode_all_packets(dec, packets[serial])
#         break
#     end
#
#     if audio == nothing
#         error("Could not find any Opus streams!")
#     end
#     return audio, 48000
# end
#
# function load(file_path::Union{File{format"OPUS"},AbstractString})
#     open(file_path) do fio
#         return load(fio)
#     end
# end
