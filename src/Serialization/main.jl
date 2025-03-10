# This type should not be exported and should be before serializers
const BasicTypeUnion = Union{String, QQFieldElem, Symbol,
                       Number, ZZRingElem, TropicalSemiringElem}

include("serializers.jl")

const type_key = :_type
const refs_key = :_refs
################################################################################
# Meta Data

@Base.kwdef struct MetaData
  author_orcid::Union{String, Nothing} = nothing
  name::Union{String, Nothing} = nothing
  description::Union{String, Nothing} = nothing
end

function metadata(;args...)
  return MetaData(;args...)
end

function read_metadata(filename::String)
  open(filename) do io
    obj = JSON3.read(io)
    println(json(obj[:meta], 2))
  end
end

################################################################################
# Serialization info

function serialization_version_info(obj::Union{JSON3.Object, Dict})
  ns = obj[:_ns]
  version_info = ns[:Oscar][2]
  if version_info isa JSON3.Object
    return version_number(Dict(version_info))
  end
  return version_number(version_info)
end

function version_number(v_number::String)
  return VersionNumber(v_number)
end

# needed for older versions
function version_number(dict::Dict)
  return VersionNumber(dict[:major], dict[:minor], dict[:patch])
end

const oscar_serialization_version = Ref{Dict{Symbol, Any}}()

function get_oscar_serialization_version()
  if isassigned(oscar_serialization_version)
    return oscar_serialization_version[]
  end
  if is_dev
    commit_hash = get(_get_oscar_git_info(), :commit, "unknown")
    version_info = "$VERSION_NUMBER-$commit_hash"
    result = Dict{Symbol, Any}(
      :Oscar => ["https://github.com/oscar-system/Oscar.jl", version_info]
    )
  else
    result = Dict{Symbol, Any}(
      :Oscar => ["https://github.com/oscar-system/Oscar.jl", VERSION_NUMBER]
    )
  end
  return oscar_serialization_version[] = result
end

################################################################################
# Type attribute map
const type_attr_map = Dict{String, Vector{Symbol}}()

################################################################################
# (De|En)coding types

# parameters of type should not matter here
const reverse_type_map = Dict{String, Type}()

function encode_type(::Type{T}) where T
  error(
    """Unsupported type '$T' for encoding. To add support see
    https://docs.oscar-system.org/stable/DeveloperDocumentation/serialization/
    """
  )
end

function decode_type(s::DeserializerState)
  if s.obj isa String
    if !isnothing(tryparse(UUID, s.obj))
      id = s.obj
      obj = s.obj
      if isnothing(s.refs)
        return typeof(global_serializer_state.id_to_obj[UUID(id)])
      end
      s.obj = s.refs[Symbol(id)]
      T = decode_type(s)
      s.obj = obj
      return T
    end

    return get(reverse_type_map, s.obj) do
      unsupported_type = s.obj
      error("unsupported type '$unsupported_type' for decoding")
    end
  end

  if type_key in keys(s.obj)
    return load_node(s, type_key) do _
      decode_type(s)
    end
  end

  if :name in keys(s.obj)
    return load_node(s, :name) do _
      decode_type(s)
    end
  end
  return decode_type(s.obj)
end

# ATTENTION
# We need to distinguish between data with a globally defined normal form and data where such a normal form depends on some parameters.
# In particular, this does NOT ONLY depend on the type; see, e.g., FqField.

################################################################################
# High level

function save_as_ref(s::SerializerState, obj::T) where T
  # find ref or create one
  ref = get(global_serializer_state.obj_to_id, obj, nothing)
  if ref !== nothing
    if !(ref in s.refs)
      push!(s.refs, ref)
    end
    return string(ref)
  end
  ref = global_serializer_state.obj_to_id[obj] = uuid4()
  global_serializer_state.id_to_obj[ref] = obj
  push!(s.refs, ref)
  return string(ref)
end

function save_object(s::SerializerState, x::Any, key::Symbol)
  set_key(s, key)
  save_object(s, x)
end

function save_json(s::SerializerState, x::Any)
  save_data_json(s, x)
end

function save_json(s::SerializerState, x::Any, key::Symbol)
  set_key(s, key)
  save_json(s, x)
end

function save_header(s::SerializerState, h::Dict{Symbol, Any}, key::Symbol)
  save_data_dict(s, key) do
    for (k, v) in h
      save_object(s, v, k)
    end
  end
end

function save_typed_object(s::SerializerState, x::T) where T
  if serialize_with_params(T)
    save_type_params(s, x, type_key)
    save_object(s, x, :data)
  elseif Base.issingletontype(T)
    save_object(s, encode_type(T), type_key)
  else
    save_object(s, encode_type(T), type_key)
    save_object(s, x, :data)
  end
end

function save_typed_object(s::SerializerState, x::T, key::Symbol) where T
  set_key(s, key)
  if serialize_with_id(x)
    # key should already be set before function call
    ref = save_as_ref(s, x)
    save_object(s, ref)
  else
    save_data_dict(s) do
      save_typed_object(s, x)
    end
  end
end

function save_type_params(s::SerializerState, obj::Any, key::Symbol)
  set_key(s, key)
  save_type_params(s, obj)
end

function save_attrs(s::SerializerState, obj::T) where T
  !with_attrs(s) && return 
  if any(attr -> has_attribute(obj, attr), attrs_list(s, T))
    save_data_dict(s, :attrs) do
      for attr in attrs_list(s, T)
        has_attribute(obj, attr) && save_typed_object(s, get_attribute(obj, attr), attr)
      end
    end
  end
end

# The load mechanism first checks if the type needs to load necessary
# parameters before loading it's data, if so a type tree is traversed
function load_typed_object(s::DeserializerState, key::Symbol; override_params::Any = nothing)
  load_node(s, key) do node
    if node isa String && !isnothing(tryparse(UUID, node))
      return load_ref(s)
    end
    return load_typed_object(s; override_params=override_params)
  end
end

function load_typed_object(s::DeserializerState; override_params::Any = nothing)
  T = decode_type(s)
  if Base.issingletontype(T) && return T()
  elseif serialize_with_params(T)
    if !isnothing(override_params)
      if override_params isa Dict
        error("Unsupported override type")
      else
        params = override_params
      end
    else
      # depending on the type, :params is either an object to be loaded or a
      # dict with keys and object values to be loaded
      params = load_node(s, type_key) do _
        load_params_node(s)
      end
    end
    load_node(s, :data) do _
      return load_object(s, T, params)
    end
  else
    load_node(s, :data) do _
      return load_object(s, T)
    end
  end
end

function load_object(s::DeserializerState, T::Type, key::Union{Symbol, Int})
  load_node(s, key) do _
    load_object(s, T)
  end
end

function load_object(s::DeserializerState, T::Type, params::Any, key::Union{Symbol, Int})
  load_node(s, key) do _
    load_object(s, T, params)
  end
end

function load_attrs(s::DeserializerState, obj::T) where T
  !with_attrs(s) && return

  haskey(s, :attrs) && load_node(s, :attrs) do d
    for attr in keys(d)
      set_attribute!(obj, attr, load_typed_object(s, attr))
    end
  end
end

################################################################################
# Default generic save_internal, load_internal
function save_object_generic(s::SerializerState, obj::T) where T
  save_data_dict(s, :data) do
    for n in fieldnames(T)
      if n != :__attrs
        save_typed_object(s, getfield(obj, n), Symbol(n))
      end
    end
  end
end

function load_object_generic(s::DeserializerState, ::Type{T}, dict::Dict) where T
  fields = []
  for (n,t) in zip(fieldnames(T), fieldtypes(T))
    if n!= :__attrs
      push!(fields, load_object(s, t, dict[n]))
    end
  end
  return T(fields...)
end

################################################################################
# Utility functions for parent tree

# loads parent tree
function load_parents(s::DeserializerState, parent_ids::Vector)
  loaded_parents = []
  for id in parent_ids
    loaded_parent = load_ref(s, id)
    push!(loaded_parents, loaded_parent)
  end
  return loaded_parents
end

################################################################################
# Type Registration
function register_serialization_type(@nospecialize(T::Type), str::String)
  if haskey(reverse_type_map, str) && reverse_type_map[str] != T
    error("encoded type $str already registered for a different type: $T versus $(reverse_type_map[str])")
  end
  reverse_type_map[str] = T
end

function register_attr_list(@nospecialize(T::Type),
                            attrs::Union{Vector{Symbol}, Nothing})
  if !isnothing(attrs)
    Oscar.type_attr_map[encode_type(T)] = attrs
  end
end

import Serialization.serialize
import Serialization.deserialize
import Serialization.serialize_type
import Distributed.AbstractSerializer

# add these here so that the proper errors are thrown
# when the type hasn't been registered
serialize_with_id(::Type) = false
serialize_with_id(obj::Any) = false
serialize_with_params(::Type) = false


function register_serialization_type(ex::Any, str::String, uses_id::Bool,
                                     uses_params::Bool, attrs::Any)
  return esc(
    quote
      Oscar.register_serialization_type($ex, $str)
      Oscar.encode_type(::Type{<:$ex}) = $str
      # There exist types where equality cannot be discerned from the serialization
      # these types require an id so that equalities can be forced upon load.
      # The ids are only necessary for parent types, checking for element type equality
      # can be done once the parents are known to be equal.
      # For example two serializations of QQ[x] require ids to check for equality.
      # Although they're isomorphic rings, they may want to be treated as separate
      # This is done since other software might not use symbols in their serialization of QQ[x].
      # Which will then still allow for the distinction between QQ[x] and QQ[y], i.e.
      # whenever there is a possibility (amongst any software system) that the objects
      # cannot be distinguish on a syntactic level we use ids.
      # Types like ZZ, QQ, and ZZ/nZZ do not require ids since there is no syntactic
      # ambiguities in their encodings.

      # add list of possible attributes to save for a given type to a global dict
      Oscar.register_attr_list($ex, $attrs)
      
      Oscar.serialize_with_id(obj::T) where T <: $ex = $uses_id
      Oscar.serialize_with_id(T::Type{<:$ex}) = $uses_id
      Oscar.serialize_with_params(T::Type{<:$ex}) = $uses_params

      # only extend serialize on non std julia types
      if !($ex <: Union{Number, String, Bool, Symbol, Vector, Tuple, Matrix, NamedTuple, Dict, Set})
        function Oscar.serialize(s::Oscar.AbstractSerializer, obj::T) where T <: $ex
          Oscar.serialize_type(s, T)
          Oscar.save(s.io, obj; serializer=Oscar.IPCSerializer())
        end
        function Oscar.deserialize(s::Oscar.AbstractSerializer, ::Type{<:$ex})
          Oscar.load(s.io; serializer=Oscar.IPCSerializer())
        end
      end
    end)
end

"""
    @register_serialization_type NewType "String Representation of type" uses_id uses_params [:attr1, :attr2]

`@register_serialization_type` is a macro to ensure that the string we generate
matches exactly the expression passed as first argument, and does not change
in unexpected ways when import/export statements are adjusted.

Passing a string argument will override how the type is stored as a string.

When setting `uses_id` the object will be stored as a reference and
will be referred to throughout the serialization sessions using a `UUID`.
This should typically only be used for types that do not have a fixed
normal form for example `PolyRing` and `MPolyRing`.

Using the `uses_params` flag will serialize the object with a more structured type
description which will make the serialization more efficient see the discussion on
`save_type_params` / `load_type_params` below.

Passing a vector of symbols that correspond to attributes of type
indicates which attributes will be serialized when using save with `with_attrs=true`.

"""
macro register_serialization_type(ex::Any, args...)
  uses_id = false
  uses_params = false
  str = nothing
  attrs = nothing
  for el in args
    if el isa String
      str = el
    elseif el == :uses_id
      uses_id = true
    elseif el == :uses_params
      uses_params = true
    else
      attrs = el
    end
  end
  if str === nothing
    str = string(ex)
  end

  return register_serialization_type(ex, str, uses_id, uses_params, attrs)
end


################################################################################
# Utility macro
"""
    Oscar.@import_all_serialization_functions

This macro imports all serialization related functions that one may need for implementing
serialization for custom types from Oscar into the current module.
One can instead import the functions individually if needed but this macro is provided
for convenience.
"""
macro import_all_serialization_functions()
  return quote
    import Oscar:
      load_object,
      load_type_params,
      save_object,
      save_type_params

    using Oscar:
      @register_serialization_type,
      DeserializerState,
      SerializerState,
      encode_type,
      haskey,
      load_array_node,
      load_attrs,
      load_node,
      load_params_node,
      load_ref,
      load_typed_object,
      save_as_ref,
      save_attrs,
      save_data_array,
      save_data_basic,
      save_data_dict,
      save_data_json,
      save_typed_object,
      serialize_with_id,
      serialize_with_params,
      set_key,
      with_attrs,
      type_attr_map
  end
end


################################################################################
# Include serialization implementations for various types

include("basic_types.jl")
include("containers.jl")
include("PolyhedralGeometry.jl")
include("Combinatorics.jl")
include("Fields.jl")
include("ToricGeometry.jl")
include("Rings.jl")
include("MPolyMap.jl")
include("Algebras.jl")
include("polymake.jl")
include("TropicalGeometry.jl")
include("QuadForm.jl")
include("GAP.jl")
include("Groups.jl")
include("LieTheory.jl")

include("Upgrades/main.jl")

################################################################################
# Interacting with IO streams and files

"""
    save(io::IO, obj::Any; metadata::MetaData=nothing, with_attrs::Bool=true)
    save(filename::String, obj::Any, metadata::MetaData=nothing, with_attrs::Bool=true)

Save an object `obj` to the given io stream
respectively to the file `filename`. When used with `with_attrs=true` then the object will
save it's attributes along with all the attributes of the types used in the object's struct.
The attributes that will be saved are defined during type registration see
[`@register_serialization_type`](@ref)

See [`load`](@ref).

# Examples

```jldoctest
julia> meta = metadata(author_orcid="0000-0000-0000-0042", name="42", description="The meaning of life, the universe and everything")
Oscar.MetaData("0000-0000-0000-0042", "42", "The meaning of life, the universe and everything")

julia> save("/tmp/fourtitwo.mrdi", 42; metadata=meta);

julia> read_metadata("/tmp/fourtitwo.mrdi")
{
  "author_orcid": "0000-0000-0000-0042",
  "name": "42",
  "description": "The meaning of life, the universe and everything"
}

julia> load("/tmp/fourtitwo.mrdi")
42
```
"""
function save(io::IO, obj::T; metadata::Union{MetaData, Nothing}=nothing,
              with_attrs::Bool=true,
              serializer::OscarSerializer = JSONSerializer()) where T
  s = serializer_open(io, serializer, with_attrs)
  save_data_dict(s) do 
    # write out the namespace first
    save_header(s, get_oscar_serialization_version(), :_ns)

    save_typed_object(s, obj)

    if serialize_with_id(T)
      ref = get(global_serializer_state.obj_to_id, obj, nothing)
      if isnothing(ref)
        ref = global_serializer_state.obj_to_id[obj] = uuid4()
        global_serializer_state.id_to_obj[ref] = obj
      end
      save_object(s, string(ref), :id)
    end

    handle_refs(s)

    if !isnothing(metadata)
      save_json(s, JSON3.write(metadata), :meta)
    end
  end
  serializer_close(s)
  return nothing
end

function save(filename::String, obj::Any;
              metadata::Union{MetaData, Nothing}=nothing,
              serializer::OscarSerializer=JSONSerializer(),
              with_attrs::Bool=true)
  dir_name = dirname(filename)
  # julia dirname does not return "." for plain filenames without any slashes
  temp_file = tempname(isempty(dir_name) ? pwd() : dir_name)
  
  open(temp_file, "w") do file
    save(file, obj;
         metadata=metadata,
         with_attrs=with_attrs,
         serializer=serializer)
  end
  Base.Filesystem.rename(temp_file, filename) # atomic "multi process safe"
  return nothing
end

"""
    load(io::IO; params::Any = nothing, type::Any = nothing, with_attrs::Bool=true)
    load(filename::String; params::Any = nothing, type::Any = nothing, with_attrs::Bool=true)

Load the object stored in the given io stream
respectively in the file `filename`.

If `params` is specified, then the root object of the loaded data
either will attempt a load using these parameters. In the case of Rings this
results in setting its parent, or in the case of a container of ring types such as
`Vector` or `Tuple`, then the parent of the entries will be set using their
 `params`.

If a type `T` is given then attempt to load the root object of the data
being loaded with this type; if this fails, an error is thrown.

If `with_attrs=true` the object will be loaded with attributes available from
the file (or serialized data).

See [`save`](@ref).

# Examples

```jldoctest
julia> save("/tmp/fourtitwo.mrdi", 42);

julia> load("/tmp/fourtitwo.mrdi")
42

julia> load("/tmp/fourtitwo.mrdi"; type=Int64)
42

julia> R, x = QQ[:x]
(Univariate polynomial ring in x over QQ, x)

julia> p = x^2 - x + 1
x^2 - x + 1

julia> save("/tmp/p.mrdi", p)

julia> p_loaded = load("/tmp/p.mrdi", params=R)
x^2 - x + 1

julia> parent(p_loaded) === R
true

julia> save("/tmp/p_v.mrdi", [p, p])

julia> loaded_p_v = load("/tmp/p_v.mrdi", params=R)
2-element Vector{QQPolyRingElem}:
 x^2 - x + 1
 x^2 - x + 1

julia> parent(loaded_p_v[1]) === parent(loaded_p_v[2]) === R
true
```
"""
function load(io::IO; params::Any = nothing, type::Any = nothing,
              serializer=JSONSerializer(), with_attrs::Bool=true)
  s = deserializer_open(io, serializer, with_attrs)
  if haskey(s.obj, :id)
    id = s.obj[:id]
    if haskey(global_serializer_state.id_to_obj, UUID(id))
      return global_serializer_state.id_to_obj[UUID(id)]
    end
  end

  # handle different namespaces
  polymake_obj = load_node(s) do d
    @req :_ns in keys(d) "Namespace is missing"
    load_node(s, :_ns) do _ns
      if :polymake in keys(_ns)
        return load_from_polymake(Dict(d))
      end
    end
  end
  if !isnothing(polymake_obj)
    return polymake_obj
  end

  load_node(s, :_ns) do _ns
    @req haskey(_ns, :Oscar) "Not an Oscar object"
  end

  # deal with upgrades
  file_version = load_node(s) do obj
    serialization_version_info(obj)
  end

  if file_version < VERSION_NUMBER
    # we need a mutable dictionary
    jsondict = copy(s.obj)
    jsondict = upgrade(file_version, jsondict)
    jsondict_str = JSON3.write(jsondict)
    s = deserializer_open(IOBuffer(jsondict_str),
                                serializer,
                                with_attrs)
  end

  try
    if type !== nothing
      # Decode the stored type, and compare it to the type `T` supplied by the caller.
      # If they are identical, just proceed. If not, then we assume that either
      # `T` is concrete, in which case `T <: U` should hold; or else `U` is
      # concrete, and `U <: T` should hold.
      #
      # This check should maybe change to a check on the whole type tree?
      U = load_node(s, type_key) do _
        decode_type(s)
      end
      U <: type || U >: type || error("Type in file doesn't match target type: $(dict[type_key]) not a subtype of $T")

      if serialize_with_params(type)
        if isnothing(params)
          params = load_node(s, type_key) do _
            load_params_node(s)
          end
        end

        load_node(s, :data) do _
          loaded = load_object(s, type, params)
        end
      else
        Base.issingletontype(type) && return type()
        load_node(s, :data) do _
          loaded = load_object(s, type)
        end
      end
    else
      loaded = load_typed_object(s; override_params=params)
    end

    if :id in keys(s.obj)
      load_node(s, :id) do id
        global_serializer_state.obj_to_id[loaded] = UUID(id)
        global_serializer_state.id_to_obj[UUID(id)] = loaded
      end
    end
    return loaded
  catch e
    if VersionNumber(replace(string(file_version), r"DEV.+" => "DEV")) > VERSION_NUMBER
      @warn """
      Attempted loading file stored with Oscar version $file_version
      using Oscar version $VERSION_NUMBER
      """
    end

    if contains(string(file_version), "DEV")
      commit = split(string(file_version), "-")[end]
      @warn "Attempted loading file stored using a DEV version with commit $commit"
    end
    rethrow(e)
  end
end

function load(filename::String; params::Any = nothing,
              type::Any = nothing, with_attrs::Bool=true,
              serializer::OscarSerializer=JSONSerializer())
  open(filename) do file
    return load(file; params=params, type=type, serializer=serializer)
  end
end
