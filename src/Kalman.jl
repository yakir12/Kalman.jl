module Kalman

using Distributions, GaussianDistributions
export LinearHomogSystem, kalmanfilter, kalmanfilter!, kalmanrts, kalmanrts!, kalmanEM

# generate.jl
export sample, randmvn

include("ellipse.jl")

abstract type StateSpaceModel
end


"""
    LinearHomogSystem

Linear dynamical model with linear observation scheme
"""
mutable struct LinearHomogSystem{Tx,TP,Ty,TPhi,T3,T4} <: StateSpaceModel
        # Initial x1 ~ N(x0, P0)   
        x0::Tx  # d
        P0::TP # dxd

        # Evolution x -> Phi x + b + w, w ~ N(0, Q)
        Phi::TPhi # dxd
        b::Tx # d
        Q::TP # dxd
         
        # Observational model y = H*x + v, v ~ N(0, R)
        y::Ty # d₂ "shadow" value
        H::T3 # d₂xd
        R::T4 # d₂xd₂
end

dims(SSM) = size(SSM.H)
llikelihood(yres, S, SSM) = logpdf(Gaussian(zero(yres), S), yres)

"""
    predict!(s, x, P, t, M::LinearHomogSystem) -> x, Ppred, Phi
"""
function predict!(s, x, P, t, M::LinearHomogSystem)
    x = M.Phi*x + M.b
    Ppred = M.Phi*P*M.Phi' + M.Q
    x, Ppred, M.Phi
end

"""
    evolve(s, x, P, t, M::LinearHomogSystem) -> x
"""
function evolve(s, x, P, t, M::LinearHomogSystem)
    M.Phi*x + M.b
    x
end

"""
    observe!(s, x, P, t, y, M::LinearHomogSystem) -> t, y, H, R
"""
function observe!(s, x, P, t, Y, M::LinearHomogSystem)
    t, Y, M.H, M.R
end

function correct!(x, Ppred, y, H, R, SSM)
    yres = y - H*x # innovation residual

    S = H*Ppred*H' + R # innovation covariance
 
    K = Ppred*H'/S # Kalman gain
    x = x + K*yres
    P = (I - K*H)*Ppred # Ppred - Ppred*H' * inv(H*Ppred*H' + R) * H* Ppred
    x, P, yres, S, K
end

# single Kalman filter step
function kalman_kernel(s, x, P, t, Y, SSM)
   
    x, Ppred, Phi = predict!(s, x, P, t, SSM)

    t, y, H, R = observe!(s, x, P, t, Y, SSM)

    x, P, yres, S, K = correct!(x, Ppred, y, H, R, SSM)

    ll = llikelihood(yres, S, SSM)
    
    t, x, P, Ppred, ll, K
end


"""
    ll, xxf = kalmanfilter(yy::Matrix, M::LinearHomogSystem) 

Kalman filter

    yy -- d₂xn array
    M -- linear model
    ll -- marginal likelihood
    xxf -- filtered process
"""
function kalmanfilter(yy::AbstractMatrix, M::LinearHomogSystem) 
    d = size(M.Phi, 1)
    n = size(yy, 2)
    kalmanfilter!(1:n, yy, zeros(d, n), zeros(d, d, n), zeros(d, d, n), M) 
end

"""
    ll, X = kalmanfilter{T}(Y::Array{T,3}, M::LinearHomogSystem)

Stack Kalman filter

    Y -- array of m independent processes (dxnxm array)

    X -- filtered processes (dxnxm array)
    ll -- product marginal log likelihood
""" 
function kalmanfilter(Y::AbstractArray{T,3}, M::LinearHomogSystem) where {T}
    d₂, n, m= size(Y)
    d = length(M.x0)
    X = zeros(d,n,m)
    PP = zeros(d, d, n)
    PPpred = zeros(d, d, n)
    ll = 0.
    for j in 1:m
        ll += kalmanfilter!(0:n, view(Y, :, :, j), view(X, :, :, j),  PP, PPpred, M)[4]
    end
    ll, X
end

# Matrix-of-vectors-version
function kalmanfilter(Y::AbstractMatrix{Ty}, M::LinearHomogSystem{Tx,TP,Ty}) where {Tx,TP,Ty}
    n, m = size(Y)
    X = zeros(Tx, n, m)
    PP = zeros(TP, n)
    PPpred = zeros(TP, n)
    ll = 0.
    for j in 1:m
        ll += kalmanfilter!(0:n, view(Y, :, j), view(X, :, j),  PP, PPpred, M)[4]
    end
    ll, X
end

function kalmanfilter!(tt, yy, xxf, PP, PPpred, M::LinearHomogSystem{Vector{T}}) where {T} 

    d₂, d = dims(M)
    assert(ndims(yy) == 2)
    n = size(yy,2)

    xf = M.x0
    P = M.P0
    
    ll = 0.0  
    t = tt[1]

    for i in 1:n # t, x, P, Ppred, ll, K = kalman_kernel(s, x, P, t, Y, SSM)
        t, xf, P, Ppred, l, _ = kalman_kernel(t, xf, P, tt[i+1], yy[.., i], M)
        xxf[.., i], PP[.., i], PPpred[.., i] = xf, P, Ppred                
        ll += l
    end
    xxf, PP, PPpred, ll
end

function kalmanfilter!(tt, yy, xxf, PP, PPpred, M::LinearHomogSystem) 

    n = size(yy, 1)
   
    xf = M.x0
    P = M.P0
    
    ll = 0.0  
    t = tt[1]

    for i in 1:n # t, x, P, Ppred, ll, K = kalman_kernel(s, x, P, t, Y, SSM)
        t, xf, P, Ppred, l, _ = kalman_kernel(t, xf, P, tt[i+1], yy[i], M)
        xxf[i], PP[i], PPpred[i] = xf, P, Ppred                
        ll += l
    end
    xxf, PP, PPpred, ll
end


function smoother_kernel(xs, Ps, xf, Pf, Ppred, Phi, b)
    # xs -- previous #h[i+1]
    # Ps -- previous #H[i+1]
    # xf -- xxf[:, i] #m[i]
    # Pf -- PPf[:, :, i] # Cn
    # Ppred -- PPpred[:, :, i+1] # R[i+1] = C[i] + W[i+1]

    J = Pf*Phi'/Ppred # C/(C+w)
    xs = xf +  J*(xs - (Phi*xf  + b))
    Ps = Pf + J*(Ps - Ppred)*J' 
   
    xs, Ps, J
end

function backward_kernel(xs, Ps, xf, Pf, Ppred, Phi, b)
    # xs -- previous
    # Ps -- previous
    # xf -- xxf[:, i]
    # Pf -- PPf[:, :, i]
    # Ppred -- PPpred[:, :, i+1]

    J = Pf*Phi'/Ppred
    xs = xf +  J*(xs - (Phi*xf  + b))
    Ps = Pf + J*Ppred*J' # as Ppred = M.Phi*P*M.Phi' + M.Q
   
    xs, Ps, J
end

"""
    xxs, PP, PPpred, ll = kalmanrts(yy, xxs, M::LinearHomogSystem) 

Rauch-Tung-Striebel smoother
    
    yy -- d₂xn array or 
    xxs -- empty dxn array or view
    M --  linear dynamic system and observation model
    
    xxs -- smoothed process
    PP -- smoother variance
    PPpred -- smoother prediction
    ll -- filter likelihood
"""
function kalmanrts(yy::Matrix, M::LinearHomogSystem{Vector{T}}) where {T}  
    d = size(M.Phi, 1)
    n = size(yy, 2)
    kalmanrts!(yy, zeros(d, n), zeros(d, d, n), zeros(d, d, n), M)
end

function kalmanrts!(yy, xx, PP, PPpred, M::LinearHomogSystem{Vector{T}}) where {T}  # using Rauch-Tung-Striebel
    d₂, d = size(M.H)
    assert(ndims(yy) == 2)
    n = size(yy,2)
   
    # forward pass
    
    # in place! xx = xxf = xxs
    # PP = PPf = PPs
      
    xx, PP, PPpred, ll = kalmanfilter!(0:n, yy, xx, PP, PPpred, M) 
    
    # backwards pass
    Phi, b = M.Phi, M.b
     
    # start with xf, P from forward pass
    xs = xx[:, n]
    Ps = PP[:, :, n]
 
   
    for i in n-1:-1:1
        xs, Ps, J = smoother_kernel(xs, Ps, xx[:, i],  PP[:, :, i], PPpred[:, :, i+1], Phi, b)
        xx[:, i] = xs
        PP[:, :, i] = Ps
    end
    
    xx, PP, PPpred, ll
end
 
 


"""
    X = kalmanrts{T}(Y::Array{T,3}, M::LinearHomogSystem)
    
Stack Rauch-Tung-Striebel smoother, computes the marginal smoothed states, that is it computes the
law ``p(x_i | y_{1:n})``.

    Y -- m independent processes (d₂xnxm array)

    X -- smoothed processes (dxnxm array)
"""
function kalmanrts(Y::Array{T,3}, M::LinearHomogSystem{Vector{T}}) where {T} 
    d₂, n, m= size(Y)
    d = length(M.x0)
    X = zeros(d,n,m)
    PP = zeros(d, d, n)
    PPpred = zeros(d, d, n)
    ll = 0.
    for j in 1:m
        ll += kalmanrts!(view(Y, :, :, j), view(X, :, :, j), PP, PPpred, M)[4]
    end
    ll, X
end

include("generate.jl")


#include("kalmanem.jl")


end # module
