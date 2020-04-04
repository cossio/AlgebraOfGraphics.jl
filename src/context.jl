# abstract type architecture

abstract type AbstractContextual end

abstract type AbstractContext <: AbstractContextual end

# contextual pair and map

struct ContextualPair{C, P<:NamedTuple, D<:NamedTuple} <: AbstractContextual
    context::C
    primary::P
    data::D
end
ContextualPair(context) = ContextualPair(context, NamedTuple(), NamedTuple())

function Base.:(==)(s1::ContextualPair, s2::ContextualPair)
    s1.context == s2.context && s1.primary == s2.primary && s1.data == s2.data
end

function Base.show(io::IO, c::ContextualPair{C}) where {C}
    Base.print(io, "ContextualPair of context type $C")
end

struct ContextualMap{L<:ContextualPair} <: AbstractContextual
    entries::Vector{L}
end
ContextualMap() = ContextualMap(ContextualPair(nothing))
ContextualMap(c::AbstractContextual) = ContextualMap(entries(c))

entries(c::ContextualMap)   = c.entries
entries(c::ContextualPair)  = [c]
entries(c::AbstractContext) = entries(ContextualPair(c))

function Base.show(io::IO, c::ContextualMap)
    Base.print(io, "ContextualMap of length $(length(entries(c)))")
end

Base.:(==)(s1::ContextualMap, s2::ContextualMap) = entries(s1) == entries(s2)

Base.pairs(c::ContextualMap) = collect(Iterators.flatten(pairs(cp) for cp in entries(c)))

# Algebra and constructors

function Base.:+(c1::AbstractContextual, c2::AbstractContextual)
    return ContextualMap(vcat(map(entries, (c1, c2))...))
end

function Base.:*(c1::AbstractContextual, c2::AbstractContextual)
    l = [entries(cp1 * cp2) for cp1 in entries(c1) for cp2 in entries(c2)]
    return ContextualMap(reduce(vcat, l))
end

# TODO: deal with context more carefully here?
function Base.:*(c1::ContextualPair, c2::ContextualPair)
    return merge_primary_data(c1, c2.primary => c2.data)
end

primary(; kwargs...) = ContextualPair(nothing, values(kwargs), NamedTuple())
data(t...; nt...) = ContextualPair(nothing, NamedTuple(), namedtuple(t...; nt...))

# Default: broadcast context

adjust(x, d) = x
adjust(x::NamedTuple, d) = map(v -> adjust(v, d), x)

function aos(d::NamedTuple{names}) where names
    v = broadcast((args...) -> NamedTuple{names}(args), d...)
    return v isa NamedTuple ? [v] : v
end

function Base.pairs(s::ContextualPair)
    d = aos(s.data)
    p = aos(adjust(s.primary, d))
    return p .=> d
end

function merge_primary_data(c::ContextualPair, (p, d))
    return ContextualPair(c.context, merge(c.primary, p), merge(c.data, d))
end

# slicing context

struct DimsSelector{N} <: AbstractContext
    dims::NTuple{N, Int}
end
dims(args...) = DimsSelector(args)

Base.:(==)(s1::DimsSelector, s2::DimsSelector) = s1.dims == s2.dims
Base.isless(s1::DimsSelector, s2::DimsSelector) = isless(s1.dims, s2.dims)

adjust(ds::DimsSelector, d) = [c[ds.dims...] for c in CartesianIndices(d)]

function Base.pairs(c::ContextualPair{<:DimsSelector})
    d = map(c.data) do col
        mapslices(v -> [v], col; dims=c.context.dims)
    end
    return pairs(ContextualPair(nothing, c.primary, d))
end

# data context: integers and symbols are columns

struct DataContext{T} <: AbstractContext
    table::T
end

table(x) = DataContext(coldict(x))

Base.:(==)(s1::DataContext, s2::DataContext) = s1.table == s2.table

Base.pairs(t::ContextualPair{<:DataContext}) = pairs(ContextualPair(nothing, t.primary, t.data))

function extract_column(t, col::Union{Symbol, Int}, wrap=false)
    colname = col isa Symbol ? col : columnnames(t)[col]
    v = NamedDimsArray{(colname,)}(getcolumn(t, col))
    return wrap ? fill(v) : v
end
function extract_column(t, c::DimsSelector, wrap=false)
    ra = RefArray(fill(UInt8(1), length(getcolumn(t, 1))))
    return PooledArray(ra, Dict(c => UInt8(1)))
end
extract_column(t, c::NamedTuple, wrap=false) = map(x -> extract_column(t, x, wrap), c)
extract_column(t, c::AbstractArray, wrap=false) = map(x -> extract_column(t, x, false), c)

extract_view(t, idxs) = view(t, idxs)
extract_view(t::AbstractArray, idxs) = map(v -> view(v, idxs), t)
function extract_view(t::Union{NamedTuple, Tuple}, idxs)
    map(v -> extract_view(v, idxs), t)
end

addname(name, el) = fill(NamedEntry(name, el))
addname(_, el::DimsSelector) = el
addname(names::NamedTuple, els::NamedTuple) = map(addname, names, els)

# TODO consider further optimizations with refine_perm!
function group(cols, p, d, pcols, names)
    sa = StructArray(pcols)
    list = map(finduniquesorted(sa)) do (k, idxs)
        v = extract_view(d, idxs)
        subtable = coldict(cols, idxs)
        newkey = merge(p, addname(names, k))
        ContextualPair(DataContext(subtable), newkey, v)
    end
    return ContextualMap(list)
end

function merge_primary_data(s::ContextualPair{<:DataContext}, (primary, data))
    ctx, p, d = s.context, s.primary, s.data
    cols = ctx.table
    d′ = extract_column(cols, data, true)
    d′′ = merge(d, d′)
    p′ = extract_column(cols, primary)
    ns = map(get_name, p′)
    isempty(p′) ? ContextualPair(ctx, p, d′′) : group(cols, p, d′′, map(pool, p′), ns)
end

