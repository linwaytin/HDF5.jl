using Base.Meta: isexpr, quot

# Some names don't follow the automatic conversion rules, so define how to make some
# of the translations explicitly.
const bind_exceptions = Dict{Symbol,Symbol}()

# have numbers at the end
bind_exceptions[:h5p_set_fletcher32] = :H5Pset_fletcher32
bind_exceptions[:h5p_set_fapl_sec2]  = :H5Pset_fapl_sec2
bind_exceptions[:h5p_get_fapl_ros3]  = :H5Pget_fapl_ros3
bind_exceptions[:h5p_set_fapl_ros3]  = :H5Pset_fapl_ros3
# underscore separator not removed
bind_exceptions[:h5fd_core_init]   = :H5FD_core_init
bind_exceptions[:h5fd_family_init] = :H5FD_family_init
bind_exceptions[:h5fd_log_init]    = :H5FD_log_init
bind_exceptions[:h5fd_mpio_init]   = :H5FD_mpio_init
bind_exceptions[:h5fd_multi_init]  = :H5FD_multi_init
bind_exceptions[:h5fd_sec2_init]   = :H5FD_sec2_init
bind_exceptions[:h5fd_stdio_init]  = :H5FD_stdio_init

# An expression which is injected at the beginning of the API defitions to aid in doing
# (pre)compile-time conditional compilation based on the libhdf5 version.
_libhdf5_build_ver_expr = quote
    _libhdf5_build_ver = let
        majnum, minnum, relnum = Ref{Cuint}(), Ref{Cuint}(), Ref{Cuint}()
        r = ccall(
            (:H5get_libversion, libhdf5),
            herr_t,
            (Ref{Cuint}, Ref{Cuint}, Ref{Cuint}),
            majnum,
            minnum,
            relnum
        )
        r < 0 && error("Error getting HDF5 library version")
        VersionNumber(majnum[], minnum[], relnum[])
    end
end

# We'll also use this processing pass to automatically generate documentation that simply
# lists all of the bound API functions.
const bound_api = Dict{String,Vector{String}}()

"""
    @bind h5_function(arg1::Arg1Type, ...)::ReturnType [ErrorStringOrExpression] [(lb,ub)]

A binding generator for translating `@ccall`-like declarations of HDF5 library functions
to error-checked `ccall` expressions.

The provided function name is used to define the Julia function with any trailing version
number removed (such as `h5t_open2` -> `h5t_open`). The corresponding C function name is
auto-generated by uppercasing the first few letters (up to the first `_`), the first `_` is
removed. Explicit name mappings can be made by inserting a `:jlname => :h5name` pair into
the `bind_exceptions` dictionary.

The optional `ErrorStringOrExpression` can be either a string literal or an expression
which evaluates to a string. This string is used as the message in `h5error(msg)`
call. Note that the expression may refer to any arguments by name.

The optional Tuple `(lb,ub)` is a tuple of version literals (e.g. v"1.10.5") or `nothing`
defining an inclusive lower bound (lb) and exclusive upper bound (ub) such that
the binding is only defined if `lb ≤ _libhdf5_build_ver < ub`. If either bound is `nothing`
then that bound is ignored and the version is unbounded on that side.

The declared return type in the function-like signature must be the return type of the C
function, and the Julia return type is inferred as one of the following possibilities:

1. If `ReturnType === :herr_t`, the Julia function returns `nothing` and the C return is
   used only in error checking.

2. If `ReturnType === :htri_t`, the Julia function returns a boolean indicating whether
   the return value of the C function was zero (`false`) or positive (`true`).

3. Otherwise, the C function return value is returned from the Julia function, with the
   following exceptions:

   - If the return type is an C integer type compatible with Int, the return type is
     converted to an Int.

Furthermore, the C return value is interpreted to automatically generate error checks:

1. If `ReturnType === :herr_t` or `ReturnType === :htri_t`, an error is raised when the return
   value is negative.

2. If `ReturnType === :haddr_t` or `ReturnType === :hsize_t`, an error is raised when the
   return value is equivalent to `-1 % haddr_t` and `-1 % hsize_t`, respectively.

3. If `ReturnType` is a `Ptr` expression, an error is raised when the return value is
   equal to `C_NULL`.

4. If `ReturnType` is a `Csize_t` expression, an error is raised when the return value is
   equal to `0`. Note that at least in the case of `h5t_get_member_offset`, `0` is also a
   valid return value, so it is necessary for `h5error()` to check the error stack to
   determine whether or not an error should be thrown.

5. For all other return types, it is assumed a negative value indicates error.

It is assumed that the HDF library names are given in global constants named `libhdf5`
and `libhdf5_hl`. The former is used for all `ccall`s, except if the C library name begins
with "H5DO" or "H5TB" then the latter library is used.
"""
macro bind(sig::Expr, err::Union{String,Expr}, vers::Union{Expr,Nothing}=nothing)
    expr = _bind(__module__, __source__, sig, err)
    isnothing(vers) && return esc(expr)

    isexpr(vers, :tuple) || error("Expected 2-tuple of version bounds, got ", vers)
    length(vers.args) == 2 || error("Expected 2-tuple of version bounds, got ", vers)
    lb = vers.args[1]
    ub = vers.args[2]

    if lb !== :nothing && !(isexpr(lb, :macrocall) && lb.args[1] == Symbol("@v_str"))
        error("Lower version bound must be `nothing` or version number literal, got ", lb)
    end
    if ub !== :nothing && !(isexpr(ub, :macrocall) && ub.args[1] == Symbol("@v_str"))
        error("Upper version bound must be `nothing` or version number literal, got ", ub)
    end

    if lb === :nothing && ub !== :nothing
        conditional = :(_libhdf5_build_ver < $(ub))
    elseif lb !== :nothing && ub === :nothing
        conditional = :($(lb) ≤ _libhdf5_build_ver)
    else
        conditional = :($(lb) ≤ _libhdf5_build_ver < $(ub))
    end
    conditional = Expr(:if, conditional, expr)
    return esc(Expr(:macrocall, Symbol("@static"), nothing, conditional))
end

function _bind(__module__, __source__, sig::Expr, err::Union{String,Expr,Nothing})
    sig.head === :(::) || error("return type required on function signature")

    # Pull apart return-type and rest of function declaration
    rettype = sig.args[2]::Union{Symbol,Expr}
    funcsig = sig.args[1]
    isexpr(funcsig, :call) ||
        error("expected function-like expression, found `", funcsig, "`")
    funcsig = funcsig::Expr

    # Extract function name and argument list
    jlfuncname = funcsig.args[1]::Symbol
    funcargs = funcsig.args[2:end]

    # Pull apart argument names and types
    args = Vector{Symbol}()
    argt = Vector{Union{Expr,Symbol}}()
    for ii in 1:length(funcargs)
        argex = funcargs[ii]
        if !isexpr(argex, :(::)) || !(argex.args[1] isa Symbol)
            error(
                "expected `name::type` expression in argument ", ii, ", got ", funcargs[ii]
            )
        end
        push!(args, argex.args[1])
        push!(argt, argex.args[2])
    end

    prefix, rest = split(string(jlfuncname), "_"; limit=2)
    # Translate the C function name to a local equivalent
    if haskey(bind_exceptions, jlfuncname)
        cfuncname = bind_exceptions[jlfuncname]
    else
        # turn e.g. h5f_close into H5Fclose
        cfuncname = Symbol(uppercase(prefix), rest)
        # Remove the version number if present (excluding match to literal "hdf5" suffix)
        if occursin(r"\d(?<!hdf5)$", String(jlfuncname))
            jlfuncname = Symbol(chop(String(jlfuncname); tail=1))
        end
    end

    # Store the function prototype in HDF5-module specific lists:
    funclist = get!(bound_api, uppercase(prefix), Vector{String}(undef, 0))
    string(jlfuncname) in funclist || push!(funclist, string(jlfuncname))
    # Also start building the matching doc string.
    docfunc = copy(funcsig)
    docfunc.args[1] = jlfuncname
    docstr = "    $docfunc"

    # Determine the underlying C library to call
    lib = startswith(string(cfuncname), r"H5(DO|DS|LT|TB)") ? :libhdf5_hl : :libhdf5

    # Now start building up the full expression:
    statsym = Symbol("#status#") # not using gensym() to have stable naming

    # The ccall(...) itself
    cfunclib = Expr(:tuple, quot(cfuncname), lib)
    ccallexpr = :(ccall($cfunclib, $rettype, ($(argt...),), $(args...)))

    # The error condition expression
    #  errexpr = :(@hdf5error($err))
    # avoid generating line numbers in macrocall
    errexpr = Expr(:macrocall, Symbol("@h5error"), nothing, err)
    if rettype === :Csize_t
        :($statsym == 0 % $rettype && $errexpr)
        # pass through
    elseif rettype === :haddr_t || rettype === :hsize_t
        # Error typically indicated by negative values, but some return types are unsigned
        # integers. From `H5public.h`:
        #   ADDR_UNDEF => (haddr_t)(-1)
        #   HSIZE_UNDEF => (hsize_t)(-1)
        # which are both just `-1 % $type` in Julia
        errexpr = :($statsym == -1 % $rettype && $errexpr)
    elseif isexpr(rettype, :curly) && rettype.args[1] === :Ptr
        errexpr = :($statsym == C_NULL && $errexpr)
    else
        errexpr = :($statsym < 0 && $errexpr)
    end

    # Three cases for handling the return type
    if rettype === :htri_t
        # Returns a Boolean on non-error
        returnexpr = :(return $statsym > 0)
        docstr *= " -> Bool"
    elseif rettype === :herr_t
        # Only used to indicate error status
        returnexpr = :(return nothing)
    elseif rettype === :Cint
        # Convert to Int type
        returnexpr = :(return Int($statsym))
        docstr *= " -> Int"
    else
        # Returns a value
        returnexpr = :(return $statsym)
        docstr *= " -> $rettype"
    end

    if prefix == "h5fd" && endswith(rest, "_init")
        # remove trailing _init
        drivername = rest[1:(end - 5)]
        docstr *=
            "\n\nThis function is exposed in `libhdf5` as the macro `H5FD_$(uppercase(drivername))`. " *
            "See `libhdf5` documentation for [`H5Pget_driver`]" *
            "(https://portal.hdfgroup.org/display/HDF5/H5P_GET_DRIVER).\n"
    else
        docstr *=
            "\n\nSee `libhdf5` documentation for [`$cfuncname`]" *
            "(https://portal.hdfgroup.org/display/HDF5/$(uppercase(string(funcsig.args[1])))).\n"
    end
    # Then assemble the pieces. Doing it through explicit Expr() objects
    # avoids inserting the line number nodes for the macro --- the call site
    # is instead explicitly injected into the function body via __source__.
    jlfuncsig = Expr(:call, jlfuncname, args...)
    jlfuncbody = Expr(
        :block, __source__, :(lock(liblock)), :($statsym = try
            $ccallexpr
        finally
            unlock(liblock)
        end)
    )
    if errexpr !== nothing
        push!(jlfuncbody.args, errexpr)
    end
    push!(jlfuncbody.args, returnexpr)
    jlfuncexpr = Expr(:function, jlfuncsig, jlfuncbody)
    jlfuncexpr = Expr(:macrocall, Symbol("@doc"), nothing, docstr, jlfuncexpr)
    return jlfuncexpr
end
