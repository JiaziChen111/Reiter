"""
Holds all equilibrium conditions. Used to do the LINEARIZATION Step

### INPUT

    - `Y` : [x′, y′, x, y, ϵ′] where states x = [vhistogram, z, ϵ] and controls y = [Y, N, ii, Π. wage, Ve, pᵃ]

"""
function equil_histogram{T<:Real}(Y::Vector{T}, ss::StstHistogram, fcoll::FirmColloc, sol::FirmSolution)

    @getPar __pars

    #== Extract variables ==#
    x_p1::Vector{T} = Y[ ss.iZvar[:x′] ]
    x::Vector{T}    = Y[ ss.iZvar[:x] ]
    y_p1::Vector{T} = Y[ ss.iZvar[:y′] ]
    y::Vector{T}    = Y[ ss.iZvar[:y] ]
    ϵ_shocks::Vector{T}    = Y[ ss.iZvar[:eps]  ]

    #== Unpack variables in x,x_p1,y,y_p1 ==#
    vHistogram_p1, z_aggr_p1, ϵ_i_p1  = unpack_x(x_p1, ss.ixvar)
    vHistogram , z_aggr , ϵ_i         = unpack_x(x, ss.ixvar)
    Y_p1, N_p1, ii_p1, Π_p1, wage_p1, Ve_p1, pᵃ_p1 = unpack_y(y_p1, ss.iyvar)
    Y, N, ii, Π, wage, Ve, pᵃ = unpack_y(y, ss.iyvar)

    #===================================================#
    ###   CONSTRUCT eval_v from steady-state values   ###
    #===================================================#
    p_basis  = fcoll.p_basis
    Φ_z::SparseMatrixCSC{Float64,Int64}   = fcoll.Φ_tensor.vals[2]
    cv       = sol.coeff[:,3]
    function v̂_ss(x::Vector{Float64}, z_ind::Vector{Int64}, deriv::Int64 = 0)

        @assert length(x)==length(z_ind)
        Φ_p̃ = BasisMatrix( p_basis, Direct(), x, deriv).vals[1]
        Φ_eval   = row_kron( Φ_z[ z_ind, :],  Φ_p̃ )
        return Φ_eval * cv
    end

    #== ASSERT that value function Ve coincides with v̂_ss at node points ==#
    x_nodes                = fcoll.grid_nodes[:,1]
    z_nodes::Vector{Int64} = fcoll.grid_nodes[:,2]
    res_valuefnc = value(Ve) - v̂_ss(x_nodes, z_nodes)
    @assert maxabs(res_valuefnc)<1e-10

    #===========================================================================#
    ###   CONSTRUCT itp from steady-state values and perturbation variables   ###
    #===========================================================================#
    p_bellman_nodes = fcoll.p_nodes
    n_p = length(p_bellman_nodes)

    function Ve_pri_itp{T1<:Real}(x::Vector{T1}, z_ind::Vector{Int64}, deriv::Int64 = 0)# , Ve::Vector{T}, v̂_ss::Function, p_bellman_nodes::Vector{Float64})

        @assert length(x)==length(z_ind)
        nn = length(p_bellman_nodes)

        n_x = length(x)
        ito   = Array(Int64, n_x)        ###  WARN:  linear_trans! check Size     ###
        p_high = Array(Float64, n_x)

        ###  WARN:  ito and p_high are only values          ###
        ###      :  derivative wrt x is taken using v^ss     ###
        linear_trans!(ito, p_high, p_bellman_nodes, value(x))

        dVe_ip1::Vector{T} = ( Ve_p1[n_p*(z_ind-1) + ito]   - value( Ve_p1[n_p*(z_ind-1) + ito]  ) )
        dVe_i::Vector{T}   = ( Ve_p1[n_p*(z_ind-1) + ito-1] - value( Ve_p1[n_p*(z_ind-1) + ito-1] ) )

        if deriv == 0
            ##  IMPORTANT:  capture the effect dv/dπ on the value fnc    ##
            ##              by dv/dx(ss) × dx/dπ                         ##
            v̂::Vector{T} = v̂_ss( value(x), z_ind) + v̂_ss( value(x), z_ind, 1) .* (x - value(x)) +
                            p_high .* ( dVe_ip1 ) + (1.0 - p_high) .* ( dVe_i )
            return v̂
        elseif deriv ==1
            ∂v̂::Vector{T} = v̂_ss( value(x), z_ind, 1 ) + v̂_ss( value(x), z_ind, 2) .* (x - value(x)) +
                            1.0 ./ ( p_bellman_nodes[ito] - p_bellman_nodes[ito-1] ) .* ( dVe_ip1 - dVe_i )
            return ∂v̂
        elseif deriv ==2
            ∂²v̂::Vector{Float64} = v̂_ss( value(x), z_ind, 2 )
            return ∂²v̂
        end
    end

    ##  Equation:  VALUE FUNCTION  ##
    _, Ve_backward = get_xi_at(p_bellman_nodes, Ve_pri_itp, sol.pstar, wage, Y, Y_p1, Π_p1, z_aggr)
    res_bellman::Vector{T} = Ve - Ve_backward
    ###  NOTE:  ENVELOPE condition holds, so we don't need to keep     ###
    ###         track of derivatives on price                          ###

    # .....................................................................................

    ##  Equation:  FOC for the price     ##
    res_foc = foc_price_adjust_eval_v(pᵃ, Ve_pri_itp, wage, Y, Y_p1, Π_p1, z_aggr)

    # .....................................................................................

    ###  Equation:  Household optimality   ###

    res_household = Array(T,2)

    res_household[1] = 1 - β * ( Y_p1/Y )^(-σ) * (1.0+ii)/Π_p1
    res_household[2] = N^(1/ϕ) - 1/ss.χ * Y^(-σ) * wage           # eq # 332 CHECK no η term
    # res_household[2] = N_p1^(1/ϕ) - 1/ss.χ * Y_p1^(-σ) * wage           # eq # 332 CHECK no η term

    # .....................................................................................

    ###  Equation : EQUILIBRIUM conditions  ###

    res_equil = Array(T,3)

    #== TAYLOR rule ==#
    res_equil[1] = ii - (1/β-1.0) - phi_taylor*(log(Π)) - ϵ_i          # eq # 333 CHECK no η term
    # res_equil[1] = ii_p1 - (1/β-1.0) - phi_taylor*log(Π_p1) - ϵ_i_p1          # eq # 333 CHECK no η term

    #== LABOR MARKET clearing ==#
    hist_nodes, (p_hist_nodes, z_hist_nodes) = nodes(ss)
    ξstar_distr, _ = get_xi_at(p_hist_nodes, Ve_pri_itp, sol.pstar, wage, Y, Y_p1, Π_p1, z_aggr)
    ###  NOTE:  ENVELOPE condition holds, so we don't need to keep     ###
    ###         track of derivatives on price                          ###

    Π0 = Πadj_transition(p_hist_nodes, Π)
    Π1 = endperiod_transition( p_hist_nodes, pᵃ, ξstar_distr, Π; update_idio=false ) ###  WARN:  NO-adjustment of idio values  ###
    vHistogram_begin = Π0 * vHistogram
    vHistogram_end   = Π1 * vHistogram

    res_equil[2]    = resid_labor(hist_nodes, ξstar_distr, vHistogram_begin, vHistogram_end, Y, N, z_aggr) ##  WARN: having problems: stable eigenev > state variables ##

    #== Inflation determination ==#
    p_histogram_end = sum( reshape(vHistogram_end,length(p_hist_nodes), n_z), 2)
    p_histogram_end = squeeze(p_histogram_end,2)

    # res_equil[3] = 1.0 - dot( exp( (1-ϵ)*p_hist_nodes) , p_histogram_end )
    res_equil[3] = pricing_fnc(p_hist_nodes, pᵃ, ξstar_distr, vHistogram_begin, p_histogram_end, false) ###  2 OPTION's here   ###

    # .....................................................................................
    ##  Equation:  DISTRIBUTION  ##

    ## Transition END period real price --> BEGIN period real asset --> END period savings ##
    ##  vHistogram --> vHistogram_begin --> vHistogram_p1

    #== time t END-of-period period distribution ==#
    Π_trans = endperiod_transition( p_hist_nodes, pᵃ, ξstar_distr, Π; update_idio=true)
    vHistogram_lom = Π_trans * vHistogram


    res_distr::Vector{T} = distr2x(vHistogram_p1) - distr2x(vHistogram_lom)
    # res_distr::Vector{T} = vHistogram_p1 - vHistogram_lom                      ###  NOTE:  last element treatment     ###
    # .....................................................................................

    ###  Equation:  exogenous conditions   ###
    res_exog = Array(T,2)
    res_exog[1] = z_aggr_p1 - ρ_z * z_aggr - σ_z * ϵ_shocks[2]
    res_exog[2] = ϵ_i_p1    - σ_ii * ϵ_shocks[1]

    # %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    resid = [res_bellman;
            res_foc;
            res_household;
            res_equil;
            res_distr;
            res_exog]
end


# TODO
#
#

function unpack_x{T<:Real}(x::Vector{T}, ixvar::Dict{Symbol,UnitRange{Int64}})

    ## Histogram  ##
    vHistogram = x2distr( x[ixvar[:histogram]] )
    # vHistogram = x[ixvar[:histogram]]               ###  NOTE:  last element treatment     ###

    ## EXOGENOUS Aggregate state  ##
    z_aggr, ϵ_i = x[ ixvar[:exog_aggr] ]

    return vHistogram, z_aggr, ϵ_i
end

function unpack_y{T<:Real}(y::Vector{T}, iyvar::Dict{Symbol,UnitRange{Int64}})

    ## AGGREGATE VAR ##
    Y::T, N::T, ii::T, Π::T, wage::T = y[iyvar[:aggr]];

    ## Value fnc ##
    Ve::Vector{T} = y[iyvar[:value_fnc]];

    ## Value fnc ##
    pᵃ::Vector{T} = y[iyvar[:foc]];

    return Y, N, ii, Π, wage, Ve, pᵃ
end

function x2distr{T<:Real}(xhistogram::Vector{T})

    vHistogram = Array(T, length(xhistogram)+1 )
    copy!(vHistogram, [1.0-sum(xhistogram); xhistogram] )
end

function distr2x{T<:Real}(vHistogram::Vector{T})

    return vHistogram[2:end]
end

function value{N}(x::Array{ForwardDiff.Dual{N,Float64}})
    Float64[ x[i].value for i=1:length(x)]
end

function value(x::Array{Float64})
    identity(x)
end
