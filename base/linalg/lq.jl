# This file is a part of Julia. License is MIT: http://julialang.org/license

# LQ Factorizations

immutable LQ{T,S<:AbstractMatrix} <: Factorization{T}
    factors::S
    τ::Vector{T}
    LQ(factors::AbstractMatrix{T}, τ::Vector{T}) = new(factors, τ)
end

immutable LQPackedQ{T,S<:AbstractMatrix} <: AbstractMatrix{T}
    factors::Matrix{T}
    τ::Vector{T}
    LQPackedQ(factors::AbstractMatrix{T}, τ::Vector{T}) = new(factors, τ)
end

LQ{T}(factors::AbstractMatrix{T}, τ::Vector{T}) = LQ{T,typeof(factors)}(factors, τ)
LQPackedQ{T}(factors::AbstractMatrix{T}, τ::Vector{T}) = LQPackedQ{T,typeof(factors)}(factors, τ)

lqfact!{T<:BlasFloat}(A::StridedMatrix{T}) = LQ(LAPACK.gelqf!(A)...)
lqfact{T<:BlasFloat}(A::StridedMatrix{T})  = lqfact!(copy(A))
lqfact(x::Number) = lqfact(fill(x,1,1))

function lq(A::Union{Number, AbstractMatrix}; thin::Bool=true)
    F = lqfact(A)
    F[:L], full(F[:Q], thin=thin)
end

copy(A::LQ) = LQ(copy(A.factors), copy(A.τ))
convert{T}(::Type{LQ{T}},A::LQ) = LQ(convert(AbstractMatrix{T}, A.factors), convert(Vector{T}, A.τ))
convert{T}(::Type{Factorization{T}}, A::LQ) = convert(LQ{T}, A)
ctranspose{T}(A::LQ{T}) = QR{T,typeof(A.factors)}(A.factors', A.τ)

function getindex(A::LQ, d::Symbol)
    m, n = size(A)
    if d == :L
        return tril!(A.factors[1:m, 1:min(m,n)])
    elseif d == :Q
        return LQPackedQ(A.factors,A.τ)
    else
        throw(KeyError(d))
    end
end

function getindex(A::LQPackedQ, i::Integer, j::Integer)
    x = zeros(eltype(A), size(A, 1))
    x[i] = 1
    y = zeros(eltype(A), size(A, 2))
    y[j] = 1
    return dot(x, A*y)
end

getq(A::LQ) = LQPackedQ(A.factors, A.tau)

convert{T}(::Type{LQPackedQ{T}}, Q::LQPackedQ) = LQPackedQ(convert(AbstractMatrix{T}, Q.factors), convert(Vector{T}, Q.τ))
convert{T}(::Type{AbstractMatrix{T}}, Q::LQPackedQ) = convert(LQPackedQ{T}, Q)

size(A::LQ, dim::Integer) = size(A.factors, dim)
size(A::LQ) = size(A.factors)
function size(A::LQPackedQ, dim::Integer)
    if 0 < dim && dim <= 2
        return size(A.factors, dim)
    elseif 0 < dim && dim > 2
        return 1
    else
        throw(BoundsError())
    end
end

size(A::LQPackedQ) = size(A.factors)

full(A::LQ) = A[:L]*A[:Q]
#=
We construct the full eye here, even though it seems ineffecient, because
every element in the output matrix is a function of all the elements of
the input matrix. The eye is modified by the elementary reflectors held
in A, so this is not just an indexing operation. Note that in general
explicitly constructing Q, rather than using the ldiv or mult methods,
may be a wasteful allocation.
=#
function full{T}(A::LQPackedQ{T}; thin::Bool=true)
    if thin
        LAPACK.orglq!(copy(A.factors),A.τ)
    else
        A_mul_B!(A, eye(T, size(A.factors,2), size(A.factors,1)))
    end
end

## Multiplication by LQ
A_mul_B!{T<:BlasFloat}(A::LQ{T}, B::StridedVecOrMat{T}) = A[:L]*LAPACK.ormlq!('L','N',A.factors,A.τ,B)
A_mul_B!{T<:BlasFloat}(A::LQ{T}, B::QR{T}) = L*LAPACK.ormlq!('L','N',A.factors,A.τ,full(B))
A_mul_B!{T<:BlasFloat}(A::QR{T}, B::LQ{T}) = A_mul_B!(zeros(full(A)), full(A), full(B))
function *{TA,TB}(A::LQ{TA},B::StridedVecOrMat{TB})
    TAB = promote_type(TA, TB)
    A_mul_B!(convert(Factorization{TAB},A), TB==TAB ? copy(B) : copy_oftype(B, TAB))
end
function *{TA,TB}(A::LQ{TA},B::QR{TB})
    TAB = promote_type(TA, TB)
    A_mul_B!(convert(Factorization{TAB},A), TB==TAB ? copy(B) : convert(Factorization{TAB},B))
end
function *{TA,TB}(A::QR{TA},B::LQ{TB})
    TAB = promote_type(TA, TB)
    A_mul_B!(convert(Factorization{TAB},A), TB==TAB ? copy(B) : convert(Factorization{TAB},B))
end

## Multiplication by Q
### QB
A_mul_B!{T<:BlasFloat}(A::LQPackedQ{T}, B::StridedVecOrMat{T})   = LAPACK.ormlq!('L','N',A.factors,A.τ,B)
function *{TA,TB}(A::LQPackedQ{TA},B::StridedVecOrMat{TB})
    TAB = promote_type(TA, TB)
    A_mul_B!(convert(AbstractMatrix{TAB}, A), TB==TAB ? copy(B) : copy_oftype(B, TAB))
end

### QcB
Ac_mul_B!{T<:BlasReal}(A::LQPackedQ{T}, B::StridedVecOrMat{T})    = LAPACK.ormlq!('L','T',A.factors,A.τ,B)
Ac_mul_B!{T<:BlasComplex}(A::LQPackedQ{T}, B::StridedVecOrMat{T}) = LAPACK.ormlq!('L','C',A.factors,A.τ,B)
function Ac_mul_B{TA,TB}(A::LQPackedQ{TA}, B::StridedVecOrMat{TB})
    TAB = promote_type(TA,TB)
    if size(B,1) == size(A.factors,2)
        if TB == TAB
            Ac_mul_B!(convert(AbstractMatrix{TAB}, A), copy(B))
        else
            Ac_mul_B!(convert(AbstractMatrix{TAB}, A), copy_oftype(B, TAB))
        end
    elseif size(B,1) == size(A.factors,1)
        Ac_mul_B!(convert(AbstractMatrix{TAB}, A), [B; zeros(TAB, size(A.factors, 2) - size(A.factors, 1), size(B, 2))])
    else
        throw(DimensionMismatch("first dimension of B, $(size(B,1)), must equal one of the dimensions of A, $(size(A))"))
    end
end

### AQ
A_mul_B!{T<:BlasFloat}(A::StridedMatrix{T}, B::LQPackedQ{T}) = LAPACK.ormlq!('R', 'N', B.factors, B.τ, A)
function *{TA,TB}(A::StridedMatrix{TA},B::LQPackedQ{TB})
    TAB = promote_type(TA,TB)
    if size(B.factors,2) == size(A,2)
        if TA == TAB
            A_mul_B!(copy(A),convert(AbstractMatrix{TAB},B))
        else
            A_mul_B!(convert(AbstractMatrix{TAB}, A),convert(AbstractMatrix{TAB},B))
        end
    elseif size(B.factors,1) == size(A,2)
        A_mul_B!( [A zeros(TAB, size(A,1), size(B.factors,2)-size(B.factors,1))], convert(AbstractMatrix{TAB},B))
    else
        throw(DimensionMismatch("second dimension of A, $(size(A,2)), must equal one of the dimensions of B, $(size(B))"))
    end
end

### AQc
A_mul_Bc!{T<:BlasReal}(A::StridedMatrix{T}, B::LQPackedQ{T})    = LAPACK.ormlq!('R','T',B.factors,B.τ,A)
A_mul_Bc!{T<:BlasComplex}(A::StridedMatrix{T}, B::LQPackedQ{T}) = LAPACK.ormlq!('R','C',B.factors,B.τ,A)
function A_mul_Bc{TA<:Number,TB<:Number}( A::StridedVecOrMat{TA}, B::LQPackedQ{TB})
    TAB = promote_type(TA,TB)
    A_mul_Bc!(copy_oftype(A, TAB), convert(AbstractMatrix{TAB},(B)))
end

function \{TA,Tb}(A::LQ{TA}, b::StridedVector{Tb})
    S = promote_type(TA,Tb)
    m = checksquare(A)
    m == length(b) || throw(DimensionMismatch("left hand side has $m rows, but right hand side has length $(length(b))"))
    AA = convert(Factorization{S}, A)
    x = A_ldiv_B!(AA, copy_oftype(b, S))
    return x
end
function \{TA,TB}(A::LQ{TA},B::StridedMatrix{TB})
    S = promote_type(TA,TB)
    m = checksquare(A)
    m == size(B,1) || throw(DimensionMismatch("left hand side has $m rows, but right hand side has $(size(B,1)) rows"))
    AA = convert(Factorization{S}, A)
    X = A_ldiv_B!(AA, copy_oftype(B, S))
    return X
end

function A_ldiv_B!{T}(A::LQ{T}, B::StridedVecOrMat{T})
    Ac_mul_B!(A[:Q], A_ldiv_B!(LowerTriangular(A[:L]),B))
    return B
end
