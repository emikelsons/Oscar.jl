###############################################################################
#
#  Ideals of a free associative algebra
#
###############################################################################

# Currently ideal membership relies entirely on Singular, where a degree bound
# is imposed and a inconclusive answer may be returned. We can later add the
# Groebner machinery operating purely on the Oscar types, and hence not
# necessarily be confined to a degree bound.

@doc raw"""
    mutable struct FreeAssAlgIdeal{T}

Two-sided ideal of a free associative algebra with elements of type `T`.
"""
mutable struct FreeAssAlgIdeal{T} <: Ideal{T}
  gens::IdealGens{T}
  gb::IdealGens{T}

  function FreeAssAlgIdeal(R::FreeAssAlgebra, g::Vector{T}) where T <: FreeAssAlgElem
    r = new{T}()
    r.gens = IdealGens(R, g)
    return r
  end
end

function AbstractAlgebra.expressify(a::FreeAssAlgIdeal; context = nothing)
  return Expr(:call, :ideal, [expressify(g, context = context) for g in collect(a.gens)]...)
end
@enable_all_show_via_expressify FreeAssAlgIdeal

@doc raw"""
    ideal(R::FreeAssAlgebra, g::Vector{<:FreeAssAlgElem})

Return the two-sided ideal of $R$ generated by $g$.
"""
function ideal(R::FreeAssAlgebra, g::Vector{<:FreeAssAlgElem})
  @assert all(x -> parent(x) == R, g) "parent mismatch"
  return FreeAssAlgIdeal(R, g)
end

function ideal(g::Vector{<:FreeAssAlgElem})
  @assert length(g) > 0 "cannot infer base ring"
  algebra = parent(g[1]) 
  return ideal(algebra, g)

end

function base_ring(I::FreeAssAlgIdeal{T}) where T
  return I.gens.Ox::parent_type(T)
end

function base_ring_type(::Type{<:FreeAssAlgIdeal{T}}) where T
  return parent_type(T)
end

function number_of_generators(a::FreeAssAlgIdeal)
  return length(a.gens)
end

function gen(a::FreeAssAlgIdeal{T}, i::Int) where T
  return a.gens[Val(:O), i]
end

function gens(a::FreeAssAlgIdeal{T}) where T
  return T[gen(a,i) for i in 1:ngens(a)]
end

function Base.:+(a::FreeAssAlgIdeal{T}, b::FreeAssAlgIdeal{T}) where T
  R = base_ring(a)
  @assert R == base_ring(b) "parent mismatch"
  return ideal(R, vcat(gens(a), gens(b)))
end

function Base.:*(a::FreeAssAlgIdeal{T}, b::FreeAssAlgIdeal{T}) where T
  R = base_ring(a)
  @assert R == base_ring(b) "parent mismatch"
  return ideal(R, [i*j for i in gens(a) for j in gens(b)])
end

@doc raw"""
    ideal_membership(a::FreeAssAlgElem, I::FreeAssAlgIdeal, deg_bound::Int)

Returns `true` if intermediate degree calculations bounded by `deg_bound` prove that $a$ is in $I$.
Otherwise, returning `false` indicates an inconclusive answer, but larger `deg_bound`s give more confidence in a negative answer. 
If `deg_bound` is not specified, the default value is `-1`, which means that no degree bound is imposed,
resulting in a calculation using a much slower algorithm that may not terminate, but will return a full Groebner basis if it does.
```jldoctest
julia> free, (x,y,z) = free_associative_algebra(QQ, ["x", "y", "z"]);

julia> f1 = x*y + y*z;

julia> I = ideal([f1]);

julia> ideal_membership(f1, I, 4)
true
```
"""
function ideal_membership(a::FreeAssAlgElem, I::FreeAssAlgIdeal, deg_bound::Int=-1)
  return ideal_membership(a, IdealGens(gens(I)), deg_bound)
end
function ideal_membership(a::FreeAssAlgElem, I::IdealGens{<:FreeAssAlgElem}, deg_bound::Int=-1)
  return ideal_membership(a, collect(I), deg_bound)
end
function ideal_membership(a::FreeAssAlgElem, I::Vector{<:FreeAssAlgElem}, deg_bound::Int=-1)
  R = parent(a)
  @assert all(x -> parent(x) == R, I) "parent mismatch"
  gb = groebner_basis(I, deg_bound; protocol=false)
  deg_bound = max(maximum(total_degree.(gb)),total_degree(a))
  lpring, _ = _to_lpring(R, deg_bound)

  lp_I = Singular.Ideal(lpring, lpring.(gb))
  return iszero(reduce(lpring(a), lp_I))
end

function Base.in(a::FreeAssAlgElem, I::FreeAssAlgIdeal, deg_bound::Int)
  return ideal_membership(a, I, deg_bound)
end

function (R::Singular.LPRing)(a::FreeAssAlgElem)
  B = MPolyBuildCtx(R)
  for (c, e) in zip(coefficients(a), exponent_words(a))
    push_term!(B, base_ring(R)(c), e)
  end
  return finish(B)
end

function (A::FreeAssAlgebra)(a::Singular.slpalg)
  B = MPolyBuildCtx(A)
  for (c,e) in zip(Oscar.coefficients(a), Singular.exponent_words(a))
    push_term!(B, base_ring(A)(c), e)
  end 
  return finish(B)
end

_to_lpring(a::FreeAssAlgebra, deg_bound::Int) = Singular.FreeAlgebra(base_ring(a), String.(symbols(a)), deg_bound)

@doc raw"""
    groebner_basis(I::FreeAssAlgIdeal, deg_bound::Int=-1; protocol::Bool=false)

Return the Groebner basis of `I` with respect to the degree bound `deg_bound`. If `protocol` is `true`, the protocol of the computation is also returned. The default value of `deg_bound` is `-1`, which means that no degree bound is imposed, which leads to a computation that uses a much slower algorithm, that may not terminate, but returns a full groebner basis if it does.
```jldoctest
julia> free, (x,y,z) = free_associative_algebra(QQ, ["x", "y", "z"]);

julia> f1 = x*y + y*z;

julia> f2 = x^2 + y^2;

julia> I = ideal([f1, f2]);

julia> gb = groebner_basis(I, 3; protocol=false)
Ideal generating system with elements
1 -> x*y + y*z
2 -> x^2 + y^2
3 -> y^3 + y*z^2
4 -> y^2*x + y*z*y
```
"""
function groebner_basis(I::FreeAssAlgIdeal, deg_bound::Int=-1; protocol::Bool=false)
  isdefined(I, :gb) && return I.gb
  I.gb = groebner_basis(IdealGens(gens(I)), deg_bound, protocol=protocol)
  return I.gb
end
function groebner_basis(g::IdealGens{<:FreeAssAlgElem}, deg_bound::Int=-1; protocol::Bool=false)
  gb = groebner_basis(collect(g), deg_bound, protocol=protocol)
  return IdealGens(gb)
end
function groebner_basis(g::Vector{<:FreeAssAlgElem}, deg_bound::Int=-1; protocol::Bool=false)
  R = parent(g[1])
  @assert all(x -> parent(x) == R, g) "parent mismatch"
  @assert deg_bound >= 0 || !protocol "computing with a protocol requires a degree bound"

  if deg_bound == -1
      return AbstractAlgebra.groebner_basis(g)
  end
    
  lpring, _ = _to_lpring(R, deg_bound)
  lp_I_gens = lpring.(g)

  I = Singular.Ideal(lpring, lp_I_gens)
  gb = nothing 

  Singular.with_prot(protocol) do; 
    gb = gens(Singular.std(I))
  end
  return R.(gb)
end
