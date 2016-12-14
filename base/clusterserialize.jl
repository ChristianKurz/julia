# This file is a part of Julia. License is MIT: http://julialang.org/license

import .Serializer: known_object_data, object_number, serialize_cycle, deserialize_cycle, writetag,
                      __deserialized_types__, serialize_typename, deserialize_typename,
                      TYPENAME_TAG, object_numbers

type ClusterSerializer{I<:IO} <: AbstractSerializer
    io::I
    counter::Int
    table::ObjectIdDict

    pid::Int                                     # Worker we are connected to.
    tn_obj_sent::Set{UInt64}                     # TypeName objects sent
    glbs_sent::Dict{UInt64, UInt64}              # (key,value) -> (object_id, hash_value)
    glbs_in_tnobj::Dict{UInt64, Vector{Symbol}}  # Track globals referenced in
                                                 # anonymous functions.
    anonfunc_id::UInt64

    ClusterSerializer(io::I) = new(io, 0, ObjectIdDict(), Base.worker_id_from_socket(io),
                                Set{UInt64}(), Dict{UInt64, UInt64}(), Dict{UInt64, Vector{Symbol}}(), 0)
end
ClusterSerializer(io::IO) = ClusterSerializer{typeof(io)}(io)

function deserialize(s::ClusterSerializer, ::Type{TypeName})
    full_body_sent = deserialize(s)
    number = read(s.io, UInt64)
    if !full_body_sent
        tn = get(known_object_data, number, nothing)::TypeName
        if !haskey(object_numbers, tn)
            # set up reverse mapping for serialize
            object_numbers[tn] = number
        end
        deserialize_cycle(s, tn)
    else
        tn = deserialize_typename(s, number)
    end

    # retrieve arrays of global syms sent if any and deserialize them all.
    foreach(sym->deserialize_global_from_main(s, sym), deserialize(s))
    return tn
end

function serialize(s::ClusterSerializer, t::TypeName)
    serialize_cycle(s, t) && return
    writetag(s.io, TYPENAME_TAG)

    identifier = object_number(t)
    send_whole = !(identifier in s.tn_obj_sent)
    serialize(s, send_whole)
    write(s.io, identifier)
    if send_whole
        # Track globals referenced in this anonymous function.
        # This information is used to resend modified globals when we
        # only send the identifier.
        prev = s.anonfunc_id
        s.anonfunc_id = identifier
        serialize_typename(s, t)
        s.anonfunc_id = prev
        push!(s.tn_obj_sent, identifier)
        finalizer(t, x->cleanup_tname_glbs(s, identifier))
    end

    # Send global refs if required.
    syms = syms_2b_sent(s, identifier)
    serialize(s, syms)
    foreach(sym->serialize_global_from_main(s, sym), syms)
    nothing
end

function serialize(s::ClusterSerializer, g::GlobalRef)
    # Record if required and then invoke the default GlobalRef serializer.
    sym = g.name
    if g.mod === Main && isdefined(g.mod, sym)
        v = getfield(Main, sym)
        if  !isa(v, DataType) && !isa(v, Module) &&
            (binding_module(Main, sym) === Main) && (s.anonfunc_id != 0)
            push!(get!(s.glbs_in_tnobj, s.anonfunc_id, []), sym)
        end
    end

    invoke(serialize, Tuple{AbstractSerializer, GlobalRef}, s, g)
end

# Send/resend a global object if
# a) has not been sent previously, i.e., we are seeing this object_id for the first time, or,
# b) hash value has changed or
# c) is a bitstype
function syms_2b_sent(s::ClusterSerializer, identifier)
    lst=Symbol[]
    check_syms = get(s.glbs_in_tnobj, identifier, [])
    for sym in check_syms
        v = getfield(Main, sym)

        if isbits(v)
            push!(lst, sym)
        else
            oid = object_id(v)
            if haskey(s.glbs_sent, oid)
                # We have sent this object before, see if it has changed.
                s.glbs_sent[oid] != hash(v) && push!(lst, sym)
            else
                push!(lst, sym)
            end
        end
    end
    return unique(lst)
end

function serialize_global_from_main(s::ClusterSerializer, sym)
    v = getfield(Main, sym)

    oid = object_id(v)
    record_v = true
    if isbits(v)
        record_v = false
    elseif !haskey(s.glbs_sent, oid)
        # set up a finalizer the first time this object is sent
        try
            finalizer(v, x->delete_global_tracker(s,x))
        catch ex
            # Do not track objects that cannot be finalized.
            record_v = false
        end
    end
    record_v && (s.glbs_sent[oid] = hash(v))

    serialize(s, isconst(Main, sym))
    serialize(s, v)
end

function deserialize_global_from_main(s::ClusterSerializer, sym)
    sym_isconst = deserialize(s)
    v = deserialize(s)
    if sym_isconst
        eval(Main, :(const $sym = $v))
    else
        eval(Main, :($sym = $v))
    end
end

function delete_global_tracker(s::ClusterSerializer, v)
    oid = object_id(v)
    if haskey(s.glbs_sent, oid)
        delete!(s.glbs_sent, oid)
    end

    # TODO: If a global binding is released and gc'ed, should we release
    # it on the remote node too? Would need to record the local object_id remotely,
    # and then free it only if object_id matches the recorded it. Else, it could
    # be pointing to new valid data.
end

function cleanup_tname_glbs(s::ClusterSerializer, identifier)
    delete!(s.glbs_in_tnobj, identifier)
end

# TODO: cleanup from s.tn_obj_sent
