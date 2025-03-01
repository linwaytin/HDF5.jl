function Base.show(io::IO, fid::File)
    if isvalid(fid)
        intent    = API.h5f_get_intent(fid)
        RW_MASK   = API.H5F_ACC_RDONLY | API.H5F_ACC_RDWR
        SWMR_MASK = API.H5F_ACC_SWMR_READ | API.H5F_ACC_SWMR_WRITE
        rw        = (intent & RW_MASK) == API.H5F_ACC_RDONLY ? "(read-only" : "(read-write"
        swmr      = (intent & SWMR_MASK) != 0 ? ", swmr) " : ") "
        print(io, "HDF5.File: ", rw, swmr, fid.filename)
    else
        print(io, "HDF5.File: (closed) ", fid.filename)
    end
end

function Base.show(io::IO, g::Group)
    if isvalid(g)
        print(io, "HDF5.Group: ", name(g), " (file: ", g.file.filename, ")")
    else
        print(io, "HDF5.Group: (invalid)")
    end
end

function Base.show(io::IO, prop::Properties)
    print(io, typeof(prop))
    if prop.id == API.H5P_DEFAULT
        print(io, "()")
    elseif !isvalid(prop)
        print(io, ": (invalid)")
    else
        print(io, "(")
        for name in all_propertynames(typeof(prop))
            # skip deprecated names
            if name in (:compress, :track_times, :fapl_mpio)
                continue
            end
            # not all properties have getters (e.g. shuffle, deflate, etc.),
            # or always well-defined (e.g. chunk if layout != :chunked, dxpl_mpio if no MPI)
            try
                val = getproperty(prop, name)
                print(io, "\n  ", rpad(name, 15), " = ", repr(val), ",")
            catch e
            end
        end
        print(io, "\n)")
    end
end

function Base.show(io::IO, dset::Dataset)
    if isvalid(dset)
        print(
            io,
            "HDF5.Dataset: ",
            name(dset),
            " (file: ",
            dset.file.filename,
            " xfer_mode: ",
            dset.xfer.id,
            ")"
        )
    else
        print(io, "HDF5.Dataset: (invalid)")
    end
end

function Base.show(io::IO, attr::Attribute)
    if isvalid(attr)
        print(io, "HDF5.Attribute: ", name(attr))
    else
        print(io, "HDF5.Attribute: (invalid)")
    end
end
function Base.show(io::IO, attr::Attributes)
    print(io, "Attributes of ", attr.parent)
end

Base.show(io::IO, attrdict::AttributeDict) = summary(io, attrdict)
function Base.summary(io::IO, attrdict::AttributeDict)
    print(io, "AttributeDict of ", attrdict.parent)
    if isvalid(attrdict.parent)
        n = length(attrdict)
        print(io, " with ", n, n == 1 ? " attribute" : " attributes")
    end
end

const ENDIAN_DICT = Dict(
    API.H5T_ORDER_LE    => "little endian byte order",
    API.H5T_ORDER_BE    => "big endian byte order",
    API.H5T_ORDER_VAX   => "vax mixed endian byte order",
    API.H5T_ORDER_MIXED => "mixed endian byte order",
    API.H5T_ORDER_NONE  => "no particular byte order",
)

function Base.show(io::IO, dtype::Datatype)
    print(io, "HDF5.Datatype: ")
    if isvalid(dtype)
        API.h5t_committed(dtype) && print(io, name(dtype), " ")
        buffer = IOBuffer(; sizehint=18)
        print(buffer, API.h5lt_dtype_to_text(dtype))
        str = String(take!(buffer))
        if str == "undefined integer"
            println(io, str)
            println(io, "         size: ", API.h5t_get_size(dtype), " bytes")
            println(io, "    precision: ", API.h5t_get_precision(dtype), " bits")
            println(io, "       offset: ", API.h5t_get_offset(dtype), " bits")
            print(io, "        order: ", ENDIAN_DICT[API.h5t_get_order(dtype)])
        else
            print(io, str)
        end
    else
        # Note that API.h5i_is_valid returns `false` on the built-in datatypes (e.g. API.H5T_NATIVE_INT),
        # apparently because they have refcounts of 0 yet are always valid. Just temporarily turn
        # off error printing and try the call to probe if dtype is valid since API.H5LTdtype_to_text
        # special-cases all of the built-in types internally.
        local text
        try
            text = API.h5lt_dtype_to_text(dtype)
        catch
            text = "(invalid)"
        end
        print(io, text)
    end
end

function Base.show(io::IO, br::BlockRange)
    start = Int(br.start0 + 1)
    # choose the simplest possible representation
    if br.count == 1
        if br.block == 1
            # integer
            r = start
        else
            # UnitRange
            r = range(start; length=Int(br.block))
        end
    elseif br.block == 1 && br.count != API.H5S_UNLIMITED
        # StepRange
        r = range(start; step=Int(br.stride), length=Int(br.count))
    else
        # BlockRange(int; ...)
        print(io, BlockRange, "(start=", start)
        if br.stride != 1
            print(io, ", stride=", Int(br.stride))
        end
        if br.count != 1
            print(io, ", count=", br.count == API.API.H5S_UNLIMITED ? -1 : Int(br.count))
        end
        if br.block != 1
            print(io, ", block=", Int(br.block))
        end
        print(io, ")")
        return nothing
    end
    compact = get(io, :compact, false)
    compact || print(io, BlockRange, "(")
    print(io, r)
    compact || print(io, ")")
    return nothing
end

function Base.show(io::IO, dspace::Dataspace)
    if !isvalid(dspace)
        print(io, "HDF5.Dataspace: (invalid)")
        return nothing
    end
    print(io, "HDF5.Dataspace: ")
    type = API.h5s_get_simple_extent_type(dspace)
    if type == API.H5S_NULL
        print(io, "H5S_NULL")
        return nothing
    elseif type == API.H5S_SCALAR
        print(io, "H5S_SCALAR")
        return nothing
    end
    # otherwise type == API.H5S_SIMPLE
    sz, maxsz = get_extent_dims(dspace)
    sel = API.h5s_get_select_type(dspace)
    if sel == API.H5S_SEL_HYPERSLABS && API.h5s_is_regular_hyperslab(dspace)
        io_compact = IOContext(io, :compact => true)
        blockranges = get_regular_hyperslab(dspace)
        ndims = length(blockranges)
        print(io_compact, "(")
        for ii in 1:ndims
            print(io_compact, blockranges[ii])
            ii != ndims && print(io_compact, ", ")
        end
        print(io_compact, ") / (")
        for ii in 1:ndims
            print(io_compact, 1:maxsz[ii])
            ii != ndims && print(io_compact, ", ")
        end
        print(io_compact, ")")
    else
        print(io, sz)
        if maxsz != sz
            print(io, " / ", maxsz)
        end
        if sel != API.H5S_SEL_ALL
            print(io, " [irregular selection]")
        end
    end
end

"""
    SHOW_TREE_ICONS = Ref{Bool}(true)

Configurable option to control whether emoji icons (`true`) or a plain-text annotation
(`false`) is used to indicate the object type by `show_tree`.
"""
const SHOW_TREE_ICONS = Ref{Bool}(true)

"""
    SHOW_TREE_MAX_DEPTH = Ref{Int}(5)

Maximum recursive depth to descend during printing.
"""
const SHOW_TREE_MAX_DEPTH = Ref{Int}(5)

"""
    SHOW_TREE_MAX_CHILDREN = Ref{Int}(50)

Maximum number of children to show at each node.
"""
const SHOW_TREE_MAX_CHILDREN = Ref{Int}(50)

function Base.show(
    io::IO, ::MIME"text/plain", obj::Union{File,Group,Dataset,Attributes,Attribute}
)
    if get(io, :compact, false)::Bool
        show(io, obj)
    else
        show_tree(io, obj)
    end
end

_tree_icon(::Type{Attribute}) = SHOW_TREE_ICONS[] ? "🏷️" : "[A]"
_tree_icon(::Type{Group})     = SHOW_TREE_ICONS[] ? "📂" : "[G]"
_tree_icon(::Type{Dataset})   = SHOW_TREE_ICONS[] ? "🔢" : "[D]"
_tree_icon(::Type{Datatype})  = SHOW_TREE_ICONS[] ? "📄" : "[T]"
_tree_icon(::Type{File})      = SHOW_TREE_ICONS[] ? "🗂️" : "[F]"
_tree_icon(::Type)            = SHOW_TREE_ICONS[] ? "❓" : "[?]"
_tree_icon(obj)               = _tree_icon(typeof(obj))
_tree_icon(obj::Attributes)   = _tree_icon(obj.parent)

_tree_head(io::IO, obj) = print(io, _tree_icon(obj), " ", obj)
_tree_head(io::IO, obj::Datatype) =
    print(io, _tree_icon(obj), " HDF5.Datatype: ", name(obj))

_tree_count(parent::Union{File,Group}, attributes::Bool) =
    length(parent) + (attributes ? length(HDF5.attrs(parent)) : 0)
_tree_count(parent::Dataset, attributes::Bool) = attributes ? length(HDF5.attrs(parent)) : 0
_tree_count(parent::Attributes, _::Bool) = length(parent)
_tree_count(parent::Union{Attribute,Datatype}, _::Bool) = 0

function _show_tree(
    io::IO,
    obj::Union{File,Group,Dataset,Datatype,Attributes,Attribute},
    indent::String="";
    attributes::Bool=true,
    depth::Int=1
)
    isempty(indent) && _tree_head(io, obj)
    isvalid(obj) || return nothing

    INDENT = "   "
    PIPE   = "│  "
    TEE    = "├─ "
    ELBOW  = "└─ "

    limit = get(io, :limit, false)::Bool
    counter = 0
    nchildren = _tree_count(obj, attributes)

    @inline function childstr(io, n, more=" ")
        print(io, "\n", indent, ELBOW * "(", n, more, n == 1 ? "child" : "children", ")")
    end
    @inline function depth_check()
        counter += 1
        if limit && counter > max(2, SHOW_TREE_MAX_CHILDREN[] ÷ depth)
            childstr(io, nchildren - counter + 1, " more ")
            return true
        end
        return false
    end

    if limit && nchildren > 0 && depth > SHOW_TREE_MAX_DEPTH[]
        childstr(io, nchildren)
        return nothing
    end

    if attributes && !isa(obj, Attribute)
        obj′ = obj isa Attributes ? obj.parent : obj
        API.h5a_iterate(obj′, idx_type(obj′), order(obj′)) do _, cname, _
            depth_check() && return API.herr_t(1)

            name = unsafe_string(cname)
            icon = _tree_icon(Attribute)
            islast = counter == nchildren
            print(io, "\n", indent, islast ? ELBOW : TEE, icon, " ", name)
            return API.herr_t(0)
        end
    end

    typeof(obj) <: Union{File,Group} || return nothing

    API.h5l_iterate(obj, idx_type(obj), order(obj)) do loc_id, cname, _
        depth_check() && return API.herr_t(1)

        name = unsafe_string(cname)
        child = obj[name]
        icon = _tree_icon(child)

        islast = counter == nchildren
        print(io, "\n", indent, islast ? ELBOW : TEE, icon, " ", name)
        nextindent = indent * (islast ? INDENT : PIPE)
        _show_tree(io, child, nextindent; attributes=attributes, depth=depth + 1)

        close(child)
        return API.herr_t(0)
    end
    return nothing
end

show_tree(obj; kws...) = show_tree(stdout, obj; kws...)
function show_tree(io::IO, obj; kws...)
    buf = IOBuffer()
    _show_tree(IOContext(buf, io), obj; kws...)
    print(io, String(take!(buf)))
end
