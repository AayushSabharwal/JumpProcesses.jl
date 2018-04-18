###############################################################################
# Stochiometry for a given reaction is a vector of pairs mapping species id to
# stochiometric coefficient.
###############################################################################

@fastmath function evalrxrate(speciesvec::AbstractVector{T}, rxidx::S,  
                              majump::MassActionJump{U,V,W})::R where {T,S,R,U <: AbstractVector{R},V,W} 
    val = one(T) 
 
    rateconst = majump.scaled_rates[rxidx] 
    stochmat  = majump.reactant_stoch[rxidx] 
 
    @inbounds for specstoch in stochmat
        specpop = speciesvec[specstoch[1]]
        val    *= specpop
        @inbounds for k = 2:specstoch[2]
            specpop -= one(specpop)
            val     *= specpop
        end
    end

     rateconst * val
end

@inline @fastmath function executerx!(speciesvec::AbstractVector{T}, rxidx::S,  
                                      majump::MassActionJump{U,V,W}) where {T,S,U,V,W}
    net_stoch = majump.net_stoch[rxidx]
    @inbounds for specstoch in net_stoch
        speciesvec[specstoch[1]] += specstoch[2]
    end
    nothing
end

function scalerates!(unscaled_rates::AbstractVector{U}, stochmat::AbstractVector{V}) where {U,S,T,W <: Pair{S,T}, V <: AbstractVector{W}}
    @inbounds for i in eachindex(unscaled_rates)
        coef = one(T)
        @inbounds for specstoch in stochmat[i]
            coef *= factorial(specstoch[2])
        end
        unscaled_rates[i] /= coef
    end
    nothing
end

function scalerate(unscaled_rate::U, stochmat::AbstractVector{Pair{S,T}}) where {U <: Number, S, T}
    coef = one(T)
    @inbounds for specstoch in stochmat
        coef *= factorial(specstoch[2])
    end
    unscaled_rate /= coef
end
