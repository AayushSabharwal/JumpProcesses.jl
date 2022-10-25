"""
The Queue Method. This method handles conditional intensity rates.

```jl
# simulating a Hawkes process
function rate_factory(prev_rate, t0, u, params, t)
  λ0, α, β = params
  λt = prev_rate(u, params, t)

  if t == t0
    if λt ≈ λ0
      rate(u, params, s) = λ0 + α*exp(-β*(s-t))
    else
      rate(u, params, s) = prev_rate(u, params, t) + α*exp(-β*(s-t))
    end
  elseif t > t0
    if λt ≈ λ0
      rate(u, params, s) = λ0
    else
      rate = prev_rate
    end
  else
    error("t must be equal or higher than t0")
  end

  lrate = λ0
  urate = rate(u, params, t)
  if urate < lrate
    error("The upper bound rate should not be lower than the lower bound.")
  end
  L = urate == lrate ? typemax(t) : 1/(2*rate)

  return rate, lrate, urate, L
end
affect!(integrator) = integratro.u[1] += 1
jump = ConstantRateJump(rate_factory, affect!)
```
"""
mutable struct QueueMethodJumpAggregation{T, S, F1, F2, F3, RNG, DEPGR, PQ} <: AbstractSSAJumpAggregator
  next_jump::Int # the next jump to execute
  prev_jump::Int # the previous jump that was executed
  next_jump_time::T # the time of the next jump
  end_time::T # the time to stop a simulation
  cur_rates::F1 # vector of current propensity values
  sum_rate::T # sum of current propensity values
  ma_jumps::S # any MassActionJumps for the system (scalar form)
  rates::F2 # vector of rate functions for ConditionalRateJumps
  affects!::F3 # vector of affect functions for ConditionalRateJumps
  save_positions::Tuple{Bool, Bool} # tuple for whether the jumps before and/or after event
  rng::RNG # random number generator
  dep_gr::DEPGR
  pq::PQ
end

function QueueMethodJumpAggregation(nj::Int, njt::T, et::T, crs::F1, sr::T,
                                    maj::S, rs::F2, affs!::F3, sps::Tuple{Bool, Bool},
                                    rng::RNG; dep_graph = nothing,
                                    kwargs...) where {T, S, F1, F2, F3, RNG}
  if get_num_majumps(maj) > 0
    error("Mass-action jumps are not supported with the Queue Method.")
  end

  if dep_graph === nothing
    if !isempty(rs)
      error("To use ConstantRateJumps with Queue Method algorithm a dependency graph must be supplied.")
    end
  else
    dg = dep_graph
    # make sure each jump depends on itself
    add_self_dependencies!(dg)
  end

  pq = MutableBinaryMinHeap{T}()

  QueueMethodJumpAggregation{T, S, F1, F2, F3, RNG, typeof(dg), typeof(pq)}(nj, nj, njt, et, crs, sr,
                                                                        maj, rs, affs!, sps, rng, dg, pq)
end

# creating the JumpAggregation structure (tuple-based constant jumps)
function aggregate(aggregator::QueueMethod, u, p, t, end_time, conditional_jumps,
                   ma_jumps, save_positions, rng; kwargs...)
  # rates, affects!, RateWrapper = get_jump_info_fwrappers(u, p, t, conditional_jumps)
  rates, affects! = get_jump_info_fwrappers(u, p, t, conditional_jumps)


  sum_rate = zero(typeof(t))
  # cur_rates = Vector{RateWrapper}(nothing, length(conditional_jumps))
  cur_rates = Vector{Any}(nothing, length(conditional_jumps))
  next_jump = 0
  next_jump_time = typemax(typeof(t))
  QueueMethodJumpAggregation(next_jump, next_jump_time, end_time, cur_rates, sum_rate,
                             ma_jumps, rates, affects!, save_positions, rng; kwargs...)
end

# set up a new simulation and calculate the first jump / jump time
function initialize!(p::QueueMethodJumpAggregation, integrator, u, params, t)
  p.end_time = integrator.sol.prob.tspan[2]
  fill_rates_and_get_times!(p, u, params, t)
  generate_jumps!(p, integrator, u, params, t)
  nothing
end

# execute one jump, changing the system state
function execute_jumps!(p::QueueMethodJumpAggregation, integrator, u, params, t)
    # execute jump
    u = update_state!(p, integrator, u)

    # update current jump rates and times
    update_dependent_rates!(p, u, params, t)

    nothing
end

# calculate the next jump / jump time
function generate_jumps!(p::QueueMethodJumpAggregation, integrator, u, params, t)
  p.next_jump_time, p.next_jump = top_with_handle(p.pq)
  nothing
end

######################## SSA specific helper routines ########################
function update_dependent_rates!(p::QueueMethodJumpAggregation, u, params, t)
  @inbounds dep_rxs = p.dep_gr[p.next_jump]
  @unpack cur_rates, rates = p

  @inbounds for rx in dep_rxs
    @inbounds trx, cur_rates[rx] = next_time(p, rates[rx], cur_rates[rx], u, params, t)
    update!(p.pq, rx, trx)
  end

  nothing
end

function next_time(p::QueueMethodJumpAggregation, rate_factory, prev_rate, u, params, t)
  t0 = t
  @unpack end_time, rng = p
  rate = nothing
  while t < end_time
    rate, lrate, urate, L = rate_factory(prev_rate, t0, u, params, t)
    s = randexp(rng) / urate
    if s > L
      t = t + L
      continue
    end
    if urate > lrate
      v = rand(rng)
      if (v > lrate/urate) && (v > rate(u, params, t + s)/urate)
        t = t + s
        continue
      end
    end
    t = t + s
    return t, rate
  end
  return typemax(t), rate
end

# reevaulate all rates, recalculate all jump times, and reinit the priority queue
function fill_rates_and_get_times!(p::QueueMethodJumpAggregation, u, params, t)
  @unpack cur_rates, rates = p
  pqdata = Vector{eltype(t)}(undef, length(rates))
  @inbounds for (rx, rate) in enumerate(rates)
    @inbounds trx, cur_rates[rx] = next_time(p, rates[rx], cur_rates[rx], u, params,t)
    pqdata[rx] = trx
  end
  p.pq = MutableBinaryMinHeap(pqdata)
  nothing
end
