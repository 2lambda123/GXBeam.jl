"""
    AbstractSystem

Supertype for types which contain the system state, residual vector, and jacobian matrix.
"""
abstract type AbstractSystem end

"""
    SystemIndices

Structure for holding indices for accessing the state variables and equations associated
with each point and beam element in a system.
"""
struct SystemIndices
    nstates::Int                 # number of state variables
    irow_point::Vector{Int}      # pointer to residual equations for each point
    irow_elem::Vector{Int}       # pointer to residual equations for each element
    icol_body::Vector{Int}       # pointer to body-frame acceleration state variables
    icol_point::Vector{Int}      # pointer to point state variables
    icol_elem::Vector{Int}       # pointer to element state variables
end

"""
    SystemIndices(start, stop, case)

Define indices for accessing the state variables and equations associated with each point
and beam element in an assembly using the connectivity of each beam element.
"""
function SystemIndices(start, stop; static=false, expanded=false)

    # number of points
    np = max(maximum(start), maximum(stop))

    # number of elements
    ne = length(start)

    # keep track of whether state variables have been assigned to each point
    assigned = fill(false, np)

    # initialize pointers
    irow_point = Vector{Int}(undef, np)
    irow_elem = Vector{Int}(undef, ne)
    icol_body = Vector{Int}(undef, 6)
    icol_point = Vector{Int}(undef, np)
    icol_elem = Vector{Int}(undef, ne)

    # default to no body acceleration states
    icol_body .= 0

    # define pointers for state variables and equations
    irow = 1
    icol = 1

    # add other states and equations
    for ielem = 1:ne

        # add state variables and equations for the start of the beam element
        ipt = start[ielem]
        if !assigned[ipt]

            assigned[ipt] = true

            # add point state variables: u/F, θ/M
            icol_point[ipt] = icol
            icol += 6

            # add equilibrium equations: ∑F=0, ∑M=0
            irow_point[ipt] = irow
            irow += 6

            if !static
                # add velocity states and residuals: V, Ω
                icol += 6
                irow += 6
            end

        end

        # add element state variables
        irow_elem[ielem] = irow
        icol_elem[ielem] = icol
        if expanded
            # states: F1, F2, M1, M2, V, Ω
            # residuals: compatability (x1), velocity (x1), equilibrium (x1)
            irow += 18
            icol += 18
        else
            # states: F, M
            # residuals: compatability (x1)
            irow += 6
            icol += 6
        end

        # add state variables and equations for the end of the beam element
        ipt = stop[ielem]

        if !assigned[ipt]

            assigned[ipt] = true

            # add point state variables: u/F, θ/M
            icol_point[ipt] = icol
            icol += 6

            # add equilibrium equations: ∑F=0, ∑M=0
            irow_point[ipt] = irow
            irow += 6

            if !static
                # add velocity states and residuals: V, Ω
                icol += 6
                irow += 6
            end

        end
    end

    # total number of state variables
    nstates = icol - 1

    return SystemIndices(nstates, irow_point, irow_elem, icol_body, icol_point, icol_elem)
end

"""
    update_body_acceleration_indices!(system, prescribed_conditions)
    update_body_acceleration_indices!(indices, prescribed_conditions)

Updates the state variable indices corresponding to the body frame accelerations to
correspond to the provided prescribed conditions.
"""
function update_body_acceleration_indices!(system::AbstractSystem, prescribed_conditions)

    update_body_acceleration_indices!(system.indices, prescribed_conditions)

    return system
end

function update_body_acceleration_indices!(indices::SystemIndices, prescribed_conditions)

    for i = 1:6
        ipoint = findfirst(p -> p.pl[i] & p.pd[i], prescribed_conditions)
        if isnothing(ipoint)
            indices.icol_body[i] = 0
        else
            indices.icol_body[i] = indices.icol_point[ipoint]+i-1
        end
    end

    return indices
end

"""
    body_accelerations(system, x=system.x; linear_acceleration=zeros(3), angular_acceleration=zeros(3))

Extract the linear and angular acceleration of the body frame from the state vector, if
applicable.  Otherwise return the provided linear and angular acceleration.  This function
is applicable only for steady state and initial condition analyses.
"""
function body_accelerations(system::AbstractSystem, x=system.x;
    linear_acceleration=(@SVector zeros(3)),
    angular_acceleration=(@SVector zeros(3))
    )

    return body_accelerations(x, system.indices.icol_indices, linear_acceleration, angular_acceleration)
end

function body_accelerations(x, icol, ab=(@SVector zeros(3)), αb=(@SVector zeros(3)))

    ab = SVector(
        iszero(icol[1]) ? ab[1] : x[icol[1]],
        iszero(icol[2]) ? ab[2] : x[icol[2]],
        iszero(icol[3]) ? ab[3] : x[icol[3]],
    )

    αb = SVector(
        iszero(icol[4]) ? αb[1] : x[icol[4]],
        iszero(icol[5]) ? αb[2] : x[icol[5]],
        iszero(icol[6]) ? αb[3] : x[icol[6]],
    )

    return ab, αb
end

"""
    default_force_scaling(assembly)

Defines a suitable default force scaling factor based on the nonzero elements of the
compliance matrices in `assembly`.
"""
function default_force_scaling(assembly)

    TF = eltype(assembly)

    nsum = 0
    csum = zero(TF)
    for elem in assembly.elements
        for val in elem.compliance
            csum += abs(val)
            if eps(TF) < abs(val)
                nsum += 1
            end
        end
    end

    force_scaling = iszero(nsum) ? 1.0 : nextpow(2.0, nsum/csum/100)

    return force_scaling
end

"""
    StaticSystem{TF, TV<:AbstractVector{TF}, TM<:AbstractMatrix{TF}} <: AbstractSystem

Contains the system state, residual vector, and jacobian matrix for a static system.
"""
mutable struct StaticSystem{TF, TV<:AbstractVector{TF}, TM<:AbstractMatrix{TF}} <: AbstractSystem
    x::TV
    r::TV
    K::TM
    indices::SystemIndices
    force_scaling::TF
    t::TF
end
Base.eltype(::StaticSystem{TF, TV, TM}) where {TF, TV, TM} = TF

"""
    StaticSystem([TF=eltype(assembly),] assembly; kwargs...)

Initialize an object of type [`StaticSystem`](@ref).

# Arguments:
 - `TF:`(optional) Floating point type, defaults to the floating point type of `assembly`
 - `assembly`: Assembly of rigidly connected nonlinear beam elements

# Keyword Arguments
 - `force_scaling`: Factor used to scale system forces/moments internally.  If
    not specified, a suitable default will be chosen based on the entries of the
    beam element compliance matrices.
"""
function StaticSystem(assembly; kwargs...)

    return StaticSystem(eltype(assembly), assembly; kwargs...)
end

function StaticSystem(TF, assembly; force_scaling = default_force_scaling(assembly))

    # initialize system pointers
    indices = SystemIndices(assembly.start, assembly.stop, static=true, expanded=false)

    # initialize system states
    x = zeros(TF, indices.nstates)
    r = zeros(TF, indices.nstates)
    K = spzeros(TF, indices.nstates, indices.nstates)

    # initialize current time
    t = 0.0

    x, r = promote(x, r)

    return StaticSystem{TF, Vector{TF}, SparseMatrixCSC{TF, Int64}}(x, r, K, indices, force_scaling, t)
end

"""
    DynamicSystem{TF, TV<:AbstractVector{TF}, TM<:AbstractMatrix{TF}} <: AbstractSystem

Contains the system state, residual vector, and jacobian matrix for a dynamic system.
"""
mutable struct DynamicSystem{TF, TV<:AbstractVector{TF}, TM<:AbstractMatrix{TF}} <: AbstractSystem
    dx::TV
    x::TV
    r::TV
    K::TM
    M::TM
    indices::SystemIndices
    force_scaling::TF
    t::TF
end
Base.eltype(::DynamicSystem{TF, TV, TM}) where {TF, TV, TM} = TF

"""
    DynamicSystem([TF=eltype(assembly),] assembly; kwargs...)

Initialize an object of type [`DynamicSystem`](@ref).

# Arguments:
 - `TF:`(optional) Floating point type, defaults to the floating point type of `assembly`
 - `assembly`: Assembly of rigidly connected nonlinear beam elements

# Keyword Arguments
 - `force_scaling`: Factor used to scale system forces/moments internally.  If
    not specified, a suitable default will be chosen based on the entries of the
    beam element compliance matrices.
"""
function DynamicSystem(assembly; kwargs...)

    return DynamicSystem(eltype(assembly), assembly; kwargs...)
end

function DynamicSystem(TF, assembly; force_scaling = default_force_scaling(assembly))

    # initialize system pointers
    indices = SystemIndices(assembly.start, assembly.stop; static=false, expanded=false)

    # initialize system states
    dx = zeros(TF, indices.nstates)
    x = zeros(TF, indices.nstates)
    r = zeros(TF, indices.nstates)
    K = spzeros(TF, indices.nstates, indices.nstates)
    M = spzeros(TF, indices.nstates, indices.nstates)

    # initialize current body frame states and time
    t = zero(TF)

    return DynamicSystem{TF, Vector{TF}, SparseMatrixCSC{TF, Int64}}(dx, x, r, K, M,
        indices, force_scaling, t)
end

"""
    ExpandedSystem{TF, TV<:AbstractVector{TF}, TM<:AbstractMatrix{TF}} <: AbstractSystem

Contains the system state, residual vector, and jacobian matrix for a constant mass matrix
system.
"""
mutable struct ExpandedSystem{TF, TV<:AbstractVector{TF}, TM<:AbstractMatrix{TF}} <: AbstractSystem
    dx::TV
    x::TV
    r::TV
    K::TM
    M::TM
    indices::SystemIndices
    force_scaling::TF
    t::TF
end
Base.eltype(::ExpandedSystem{TF, TV, TM}) where {TF, TV, TM} = TF

"""
    ExpandedSystem([TF=eltype(assembly),] assembly; kwargs...)

Initialize an object of type [`ExpandedSystem`](@ref).

# Arguments:
 - `TF:`(optional) Floating point type, defaults to the floating point type of `assembly`
 - `assembly`: Assembly of rigidly connected nonlinear beam elements

# Keyword Arguments
 - `force_scaling`: Factor used to scale system forces/moments internally.  If
    not specified, a suitable default will be chosen based on the entries of the
    beam element compliance matrices.
"""
function ExpandedSystem(assembly; kwargs...)

    return ExpandedSystem(eltype(assembly), assembly; kwargs...)
end

function ExpandedSystem(TF, assembly; force_scaling = default_force_scaling(assembly))

    # initialize system pointers
    indices = SystemIndices(assembly.start, assembly.stop; static=false, expanded=true)

    # initialize system states
    dx = zeros(TF, indices.nstates)
    x = zeros(TF, indices.nstates)
    r = zeros(TF, indices.nstates)
    K = spzeros(TF, indices.nstates, indices.nstates)
    M = spzeros(TF, indices.nstates, indices.nstates)

    # initialize current time
    t = zero(TF)

    return ExpandedSystem{TF, Vector{TF}, SparseMatrixCSC{TF, Int64}}(dx, x, r, K, M,
        indices, force_scaling, t)
end

# default system is a DynamicSystem
const System = DynamicSystem

"""
    reset_state!(system)

Sets the state variables in `system` to zero.
"""
reset_state!

function reset_state!(system::StaticSystem)
    system.x .= 0
    return system
end

function reset_state!(system::Union{DynamicSystem,ExpandedSystem})
    system.x .= 0
    system.dx .= 0
    return system
end

"""
    static_system_residual!(resid, x, indices, two_dimensional, force_scaling,
        assembly, prescribed_conditions, distributed_loads, point_masses, gravity)

Populate the system residual vector `resid` for a static analysis
"""
function static_system_residual!(resid, x, indices, two_dimensional, force_scaling,
    assembly, prescribed_conditions, distributed_loads, point_masses, gravity)

    for ipoint = 1:length(assembly.points)
        static_point_residual!(resid, x, indices, force_scaling, assembly, ipoint,
            prescribed_conditions, point_masses, gravity)
    end

    for ielem = 1:length(assembly.elements)
        static_element_residual!(resid, x, indices, force_scaling, assembly, ielem,
            prescribed_conditions, distributed_loads, gravity)
    end

    if two_dimensional
        two_dimensional_residual!(resid, x)
    end

    return resid
end

"""
    steady_system_residual!(resid, x, indices, two_dimensional, force_scaling,
        structural_damping, assembly, prescribed_conditions, distributed_loads,
        point_masses, gravity, vb, ωb, ab, αb)

Populate the system residual vector `resid` for a steady state analysis
"""
function steady_system_residual!(resid, x, indices, two_dimensional, force_scaling,
    structural_damping, assembly, prescribed_conditions, distributed_loads, point_masses,
    gravity, linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)

    # overwrite prescribed body frame accelerations (if necessary)
    linear_acceleration, angular_acceleration = body_accelerations(x, indices.icol_body,
        linear_acceleration, angular_acceleration)

    # contributions to the residual vector from points
    for ipoint = 1:length(assembly.points)
        steady_point_residual!(resid, x, indices, force_scaling,
            assembly, ipoint, prescribed_conditions, point_masses, gravity,
            linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)
    end

    # contributions to the residual vector from elements
    for ielem = 1:length(assembly.elements)
        steady_element_residual!(resid, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)
    end

    # restrict the analysis to the x-y plane (if requested)
    if two_dimensional
        two_dimensional_residual!(resid, x)
    end

    return resid
end

"""
    initial_system_residual!(resid, x, indices, rate_vars1, rate_vars2,
        two_dimensional, force_scaling, structural_damping, assembly, prescribed_conditions,
        distributed_loads, point_masses, gravity, linear_velocity, angular_velocity,
        linear_acceleration, angular_acceleration, u0, θ0, V0, Ω0, Vdot0, Ωdot0)

Populate the system residual vector `resid` for the initialization of a time domain
simulation.
"""
function initial_system_residual!(resid, x, indices, rate_vars1, rate_vars2,
    two_dimensional, force_scaling, structural_damping, assembly, prescribed_conditions,
    distributed_loads, point_masses, gravity, linear_velocity, angular_velocity,
    linear_acceleration, angular_acceleration, u0, θ0, V0, Ω0, Vdot0, Ωdot0)

    # overwrite prescribed body frame accelerations (if necessary)
    linear_acceleration, angular_acceleration = body_accelerations(x, indices.icol_body,
        linear_acceleration, angular_acceleration)

    # contributions to the residual vector from points
    for ipoint = 1:length(assembly.points)
        initial_point_residual!(resid, x, indices, rate_vars2, force_scaling,
            assembly, ipoint, prescribed_conditions, point_masses, gravity,
            linear_velocity, angular_velocity, linear_acceleration, angular_acceleration,
            u0, θ0, V0, Ω0, Vdot0, Ωdot0)
    end

    # contributions to the residual vector from elements
    for ielem = 1:length(assembly.elements)
        initial_element_residual!(resid, x, indices, rate_vars2, force_scaling,
            structural_damping, assembly, ielem, prescribed_conditions, distributed_loads,
            gravity, linear_velocity, angular_velocity, linear_acceleration, angular_acceleration,
            u0, θ0, V0, Ω0, Vdot0, Ωdot0)
    end

    # prescribe velocity rates explicitly, if their values are not used
    for ipoint = 1:length(assembly.points)
        irow = indices.irow_point[ipoint]
        icol = indices.icol_point[ipoint]
        Vdot, Ωdot = initial_point_velocity_rates(x, ipoint, indices.icol_point,
            prescribed_conditions, Vdot0, Ωdot0, rate_vars2)
        if haskey(prescribed_conditions, ipoint)
            pd = prescribed_conditions[ipoint].pd
            !pd[1] && !rate_vars1[icol+6] && rate_vars2[icol+6] && setindex!(resid, Vdot[1] - Vdot0[ipoint][1], irow)
            !pd[2] && !rate_vars1[icol+7] && rate_vars2[icol+7] && setindex!(resid, Vdot[2] - Vdot0[ipoint][2], irow+1)
            !pd[3] && !rate_vars1[icol+8] && rate_vars2[icol+8] && setindex!(resid, Vdot[3] - Vdot0[ipoint][3], irow+2)
            !pd[4] && !rate_vars1[icol+9] && rate_vars2[icol+9] && setindex!(resid, Ωdot[1] - Ωdot0[ipoint][1], irow+3)
            !pd[5] && !rate_vars1[icol+10] && rate_vars2[icol+10] && setindex!(resid, Ωdot[2] - Ωdot0[ipoint][2], irow+4)
            !pd[6] && !rate_vars1[icol+11] && rate_vars2[icol+11] && setindex!(resid, Ωdot[3] - Ωdot0[ipoint][3], irow+5)
        else
            !rate_vars1[icol+6] && rate_vars2[icol+6] && setindex!(resid, Vdot[1] - Vdot0[ipoint][1], irow)
            !rate_vars1[icol+7] && rate_vars2[icol+7] && setindex!(resid, Vdot[2] - Vdot0[ipoint][2], irow+1)
            !rate_vars1[icol+8] && rate_vars2[icol+8] && setindex!(resid, Vdot[3] - Vdot0[ipoint][3], irow+2)
            !rate_vars1[icol+9] && rate_vars2[icol+9] && setindex!(resid, Ωdot[1] - Ωdot0[ipoint][1], irow+3)
            !rate_vars1[icol+10] && rate_vars2[icol+10] && setindex!(resid, Ωdot[2] - Ωdot0[ipoint][2], irow+4)
            !rate_vars1[icol+11] && rate_vars2[icol+11] && setindex!(resid, Ωdot[3] - Ωdot0[ipoint][3], irow+5)
        end
    end

    # restrict the analysis to the x-y plane (if requested)
    if two_dimensional
        two_dimensional_residual!(resid, x)
    end

    return resid
end

"""
    newmark_system_residual!(resid, x, indices, two_dimensional, force_scaling, structural_damping,
        assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
        linear_velocity, angular_velocity, udot_init, θdot_init, Vdot_init, Ωdot_init, dt)

Populate the system residual vector `resid` for a Newmark scheme time marching analysis.
"""
function newmark_system_residual!(resid, x, indices, two_dimensional, force_scaling, structural_damping,
    assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
    linear_velocity, angular_velocity, udot_init, θdot_init, Vdot_init, Ωdot_init, dt)

    # contributions to the residual vector from points
    for ipoint = 1:length(assembly.points)
        newmark_point_residual!(resid, x, indices, force_scaling, assembly, ipoint,
            prescribed_conditions, point_masses, gravity, linear_velocity, angular_velocity,
            udot_init, θdot_init, Vdot_init, Ωdot_init, dt)
    end

    # contributions to the residual vector from elements
    for ielem = 1:length(assembly.elements)
        newmark_element_residual!(resid, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity, Vdot_init, Ωdot_init, dt)
    end

    # restrict the analysis to the x-y plane (if requested)
    if two_dimensional
        two_dimensional_residual!(resid, x)
    end

    return resid
end

"""
    dynamic_system_residual!(resid, dx, x, indices, two_dimensional, force_scaling,
        structural_damping, assembly, prescribed_conditions, distributed_loads,
        point_masses, gravity, linear_velocity, angular_velocity)

Populate the system residual vector `resid` for a general dynamic analysis.
"""
function dynamic_system_residual!(resid, dx, x, indices, two_dimensional, force_scaling,
    structural_damping, assembly, prescribed_conditions, distributed_loads, point_masses,
    gravity, linear_velocity, angular_velocity)

    # contributions to the residual vector from points
    for ipoint = 1:length(assembly.points)
        dynamic_point_residual!(resid, dx, x, indices, force_scaling, assembly,
            ipoint, prescribed_conditions, point_masses, gravity, linear_velocity, angular_velocity)
    end

    # contributions to the residual vector from elements
    for ielem = 1:length(assembly.elements)
        dynamic_element_residual!(resid, dx, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity)
    end

    # restrict the analysis to the x-y plane (if requested)
    if two_dimensional
        two_dimensional_residual!(resid, x)
    end

    return resid
end

"""
    expanded_steady_system_residual!(resid, x, indices, two_dimensional, force_scaling, structural_damping,
        assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
        linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)

Populate the system residual vector `resid` for a constant mass matrix system.
"""
function expanded_steady_system_residual!(resid, x, indices, two_dimensional, force_scaling, structural_damping,
    assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
    linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)

    # overwrite prescribed body frame accelerations (if necessary)
    linear_acceleration, angular_acceleration = body_accelerations(x, indices.icol_body,
        linear_acceleration, angular_acceleration)

    # point residuals
    for ipoint = 1:length(assembly.points)
        expanded_steady_point_residual!(resid, x, indices, force_scaling, assembly, ipoint,
            prescribed_conditions, point_masses, gravity, linear_velocity, angular_velocity,
            linear_acceleration, angular_acceleration)
    end

    # element residuals
    for ielem = 1:length(assembly.elements)
        expanded_steady_element_residual!(resid, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)
    end

    # restrict the analysis to the x-y plane (if requested)
    if two_dimensional
        two_dimensional_residual!(resid, x)
    end

    return resid
end

"""
    expanded_dynamic_system_residual!(resid, dx, x, indices, two_dimensional, force_scaling,
        structural_damping, assembly, prescribed_conditions, distributed_loads,
        point_masses, gravity, linear_velocity, angular_velocity)

Populate the system residual vector `resid` for a constant mass matrix system.
"""
function expanded_dynamic_system_residual!(resid, dx, x, indices, two_dimensional, force_scaling,
    structural_damping, assembly, prescribed_conditions, distributed_loads, point_masses,
    gravity, linear_velocity, angular_velocity)

    # point residuals
    for ipoint = 1:length(assembly.points)
        expanded_dynamic_point_residual!(resid, dx, x, indices, force_scaling, assembly, ipoint,
            prescribed_conditions, point_masses, gravity, linear_velocity, angular_velocity)
    end

    # element residuals
    for ielem = 1:length(assembly.elements)
        expanded_dynamic_element_residual!(resid, dx, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity)
    end

    # restrict the analysis to the x-y plane (if requested)
    if two_dimensional
        two_dimensional_residual!(resid, x)
    end

    return resid
end

"""
    static_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling,
        assembly, prescribed_conditions, distributed_loads, point_masses, gravity)

Populate the system jacobian matrix `jacob` for a static analysis
"""
function static_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling,
    assembly, prescribed_conditions, distributed_loads, point_masses, gravity)

    jacob .= 0

    for ipoint = 1:length(assembly.points)
        static_point_jacobian!(jacob, x, indices, force_scaling, assembly, ipoint,
            prescribed_conditions, point_masses, gravity)
    end

    for ielem = 1:length(assembly.elements)
        static_element_jacobian!(jacob, x, indices, force_scaling, assembly, ielem,
            prescribed_conditions, distributed_loads, gravity)
    end

    if two_dimensional
        two_dimensional_jacobian!(jacob, x)
    end

    return jacob
end

"""
    steady_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling,
        structural_damping, assembly, prescribed_conditions, distributed_loads,
        point_masses, gravity, linear_velocity, angular_velocity, linear_acceleration,
        angular_acceleration)

Populate the system jacobian matrix `jacob` for a steady-state analysis
"""
function steady_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling, structural_damping,
    assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
    linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)

    jacob .= 0

    # overwrite prescribed body frame accelerations (if necessary)
    linear_acceleration, angular_acceleration = body_accelerations(x, indices.icol_body,
        linear_acceleration, angular_acceleration)

    for ipoint = 1:length(assembly.points)
        steady_point_jacobian!(jacob, x, indices, force_scaling, assembly,
            ipoint, prescribed_conditions, point_masses, gravity, linear_velocity,
            angular_velocity, linear_acceleration, angular_acceleration)
    end

    for ielem = 1:length(assembly.elements)
        steady_element_jacobian!(jacob, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)
    end

    if two_dimensional
        two_dimensional_jacobian!(jacob, x)
    end

    return jacob
end

"""
    initial_system_jacobian!(jacob, x, indices, rate_vars1, rate_vars2, two_dimensional, force_scaling,
        structural_damping, assembly, prescribed_conditions, distributed_loads,
        point_masses, gravity, linear_velocity, angular_velocity, linear_acceleration,
        angular_acceleration, u0, θ0, V0, Ω0, Vdot0, Ωdot0)

Populate the system jacobian matrix `jacob` for the initialization of a time domain
simulation.
"""
function initial_system_jacobian!(jacob, x, indices, rate_vars1, rate_vars2, two_dimensional, force_scaling,
    structural_damping, assembly, prescribed_conditions, distributed_loads, point_masses,
    gravity, linear_velocity, angular_velocity, linear_acceleration, angular_acceleration,
    u0, θ0, V0, Ω0, Vdot0, Ωdot0)

    jacob .= 0

    # overwrite prescribed body frame accelerations (if necessary)
    linear_acceleration, angular_acceleration = body_accelerations(x, indices.icol_body,
        linear_acceleration, angular_acceleration)

    for ipoint = 1:length(assembly.points)
        initial_point_jacobian!(jacob, x, indices, rate_vars2, force_scaling,
            assembly, ipoint, prescribed_conditions, point_masses, gravity,
            linear_velocity, angular_velocity, linear_acceleration, angular_acceleration,
            u0, θ0, V0, Ω0, Vdot0, Ωdot0)
    end

    for ielem = 1:length(assembly.elements)
        initial_element_jacobian!(jacob, x, indices, rate_vars2, force_scaling,
            structural_damping, assembly, ielem, prescribed_conditions,
            distributed_loads, gravity, linear_velocity, angular_velocity,
            linear_acceleration, angular_acceleration, u0, θ0, V0, Ω0, Vdot0, Ωdot0)
    end

    # replace equilibrium equations, if necessary
    for ipoint = 1:length(assembly.points)
        irow = indices.irow_point[ipoint]
        icol = indices.icol_point[ipoint]
        if haskey(prescribed_conditions, ipoint)
            pd = prescribed_conditions[ipoint].pd
            # displacements not prescribed, Vdot and Ωdot are arbitrary, F and M from compatability
            if !pd[1] && !rate_vars1[icol+6] && rate_vars2[icol+6]
                jacob[irow,:] .= 0
                jacob[irow,icol] = 1
            end
            if !pd[2] && !rate_vars1[icol+7] && rate_vars2[icol+7]
                jacob[irow+1,:] .= 0
                jacob[irow+1,icol+1] = 1
            end
            if !pd[3] && !rate_vars1[icol+8] && rate_vars2[icol+8]
                jacob[irow+2,:] .= 0
                jacob[irow+2,icol+2] = 1
            end
            if !pd[4] && !rate_vars1[icol+9] && rate_vars2[icol+9]
                jacob[irow+3,:] .= 0
                jacob[irow+3,icol+3] = 1
            end
            if !pd[5] && !rate_vars1[icol+10] && rate_vars2[icol+10]
                jacob[irow+4,:] .= 0
                jacob[irow+4,icol+4] = 1
            end
            if !pd[6] && !rate_vars1[icol+11] && rate_vars2[icol+11]
                jacob[irow+5,:] .= 0
                jacob[irow+5,icol+5] = 1
            end
        else
            if !rate_vars1[icol+6] && rate_vars2[icol+6]
                jacob[irow,:] .= 0
                jacob[irow,icol] = 1
            end
            if !rate_vars1[icol+7] && rate_vars2[icol+7]
                jacob[irow+1,:] .= 0
                jacob[irow+1,icol+1] = 1
            end
            if !rate_vars1[icol+8] && rate_vars2[icol+8]
                jacob[irow+2,:] .= 0
                jacob[irow+2,icol+2] = 1
            end
            if !rate_vars1[icol+9] && rate_vars2[icol+9]
                jacob[irow+3,:] .= 0
                jacob[irow+3,icol+3] = 1
            end
            if !rate_vars1[icol+10] && rate_vars2[icol+10]
                jacob[irow+4,:] .= 0
                jacob[irow+4,icol+4] = 1
            end
            if !rate_vars1[icol+11] && rate_vars2[icol+11]
                jacob[irow+5,:] .= 0
                jacob[irow+5,icol+5] = 1
            end
        end
    end

    if two_dimensional
        two_dimensional_jacobian!(jacob, x)
    end

    return jacob
end

"""
    newmark_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling, structural_damping,
        assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
        linear_velocity, angular_velocity, udot_init, θdot_init, Vdot_init, Ωdot_init, dt)

Populate the system jacobian matrix `jacob` for a Newmark scheme time marching analysis.
"""
function newmark_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling, structural_damping,
    assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
    linear_velocity, angular_velocity, udot_init, θdot_init, Vdot_init, Ωdot_init, dt)

    jacob .= 0

    for ipoint = 1:length(assembly.points)
        newmark_point_jacobian!(jacob, x, indices, force_scaling, assembly, ipoint,
            prescribed_conditions, point_masses, gravity, linear_velocity, angular_velocity,
            udot_init, θdot_init, Vdot_init, Ωdot_init, dt)
    end

    for ielem = 1:length(assembly.elements)
        newmark_element_jacobian!(jacob, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity, Vdot_init, Ωdot_init, dt)
    end

    if two_dimensional
        two_dimensional_jacobian!(jacob, x)
    end

    return jacob
end

"""
    dynamic_system_jacobian!(jacob, dx, x, indices, two_dimensional, force_scaling,
        structural_damping, assembly, prescribed_conditions, distributed_loads,
        point_masses, gravity, linear_velocity, angular_velocity)

Populate the system jacobian matrix `jacob` for a general dynamic analysis.
"""
function dynamic_system_jacobian!(jacob, dx, x, indices, two_dimensional, force_scaling,
    structural_damping, assembly, prescribed_conditions, distributed_loads, point_masses,
    gravity, linear_velocity, angular_velocity)

    jacob .= 0

    for ipoint = 1:length(assembly.points)
        dynamic_point_jacobian!(jacob, dx, x, indices, force_scaling, assembly,
            ipoint, prescribed_conditions, point_masses, gravity,
            linear_velocity, angular_velocity)
    end

    for ielem = 1:length(assembly.elements)
        dynamic_element_jacobian!(jacob, dx, x, indices, force_scaling, structural_damping,
            assembly, ielem, prescribed_conditions, distributed_loads, gravity,
            linear_velocity, angular_velocity)
    end

    if two_dimensional
        two_dimensional_jacobian!(jacob, x)
    end

    return jacob
end

"""
    expanded_steady_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling, structural_damping,
        assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
        ub_p, θb_p, vb_p, ωb_p, ab_p, αb_p)

Populate the system jacobian matrix `jacob` for a general dynamic analysis with a
constant mass matrix system.
"""
function expanded_steady_system_jacobian!(jacob, x, indices, two_dimensional, force_scaling,
    structural_damping, assembly, prescribed_conditions, distributed_loads, point_masses,
    gravity, linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)

    jacob .= 0

    # overwrite prescribed body frame accelerations (if necessary)
    linear_acceleration, angular_acceleration = body_accelerations(x, indices.icol_body,
        linear_acceleration, angular_acceleration)

    for ipoint = 1:length(assembly.points)
        expanded_steady_point_jacobian!(jacob, x, indices, force_scaling,
            assembly, ipoint, prescribed_conditions, point_masses, gravity,
            linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)
    end

    for ielem = 1:length(assembly.elements)
        expanded_steady_element_jacobian!(jacob, x, indices, force_scaling,
            structural_damping, assembly, ielem, prescribed_conditions, distributed_loads,
            gravity, linear_velocity, angular_velocity, linear_acceleration, angular_acceleration)
    end

    if two_dimensional
        two_dimensional_jacobian!(jacob, x)
    end

    return jacob
end

"""
    expanded_dynamic_system_jacobian!(jacob, dx, x, indices, two_dimensional, force_scaling, structural_damping,
        assembly, prescribed_conditions, distributed_loads, point_masses, gravity,
        linear_velocity, angular_velocity)

Populate the system jacobian matrix `jacob` for a general dynamic analysis with a
constant mass matrix system.
"""
function expanded_dynamic_system_jacobian!(jacob, dx, x, indices, two_dimensional, force_scaling,
    structural_damping, assembly, prescribed_conditions, distributed_loads, point_masses,
    gravity, linear_velocity, angular_velocity)

    jacob .= 0

    for ipoint = 1:length(assembly.points)
        expanded_dynamic_point_jacobian!(jacob, dx, x, indices, force_scaling, assembly,
            ipoint, prescribed_conditions, point_masses, gravity, linear_velocity, angular_velocity)
    end

    for ielem = 1:length(assembly.elements)
        expanded_dynamic_element_jacobian!(jacob, dx, x, indices, force_scaling,
            structural_damping, assembly, ielem, prescribed_conditions, distributed_loads,
            gravity, linear_velocity, angular_velocity)
    end

    if two_dimensional
        two_dimensional_jacobian!(jacob, x)
    end

    return jacob
end

"""
    system_mass_matrix!(jacob, x, indices, two_dimensional, force_scaling,  assembly,
        prescribed_conditions, point_masses)

Calculate the jacobian of the residual expressions with respect to the state rates.
"""
function system_mass_matrix!(jacob, x, indices, two_dimensional, force_scaling, assembly,
    prescribed_conditions, point_masses)

    jacob .= 0

    gamma = 1

    system_mass_matrix!(jacob, gamma, x, indices, two_dimensional, force_scaling,  assembly,
        prescribed_conditions, point_masses)

    return jacob
end

"""
    system_mass_matrix!(jacob, gamma, x, indices, two_dimensional, force_scaling, assembly,
        prescribed_conditions, point_masses)

Calculate the jacobian of the residual expressions with respect to the state rates and
add the result multiplied by `gamma` to `jacob`.
"""
function system_mass_matrix!(jacob, gamma, x, indices, two_dimensional, force_scaling, assembly,
    prescribed_conditions, point_masses)

    for ipoint = 1:length(assembly.points)
        mass_matrix_point_jacobian!(jacob, gamma, x, indices, two_dimensional, force_scaling,
            assembly, ipoint, prescribed_conditions, point_masses)
    end

    for ielem = 1:length(assembly.elements)
        mass_matrix_element_jacobian!(jacob, gamma, x, indices, two_dimensional, force_scaling,
            assembly, ielem, prescribed_conditions)
    end

    return jacob
end

"""
    expanded_system_mass_matrix(system, assembly;
        two_dimensional = false,
        prescribed_conditions=Dict{Int, PrescribedConditions}(),
        point_masses=Dict{Int, PointMass}())

Calculate the jacobian of the residual expressions with respect to the state rates for a
constant mass matrix system.
"""
function expanded_system_mass_matrix(system, assembly;
    two_dimensional=false,
    prescribed_conditions=Dict{Int, PrescribedConditions}(),
    point_masses=Dict{Int, PointMass}())

    @unpack indices, force_scaling = system

    TF = eltype(system)
    nx = expanded_indices.nstates
    jacob = spzeros(TF, nx, nx)
    gamma = -1
    pcond = typeof(prescribed_conditions) <: AbstractDict ? prescribed_conditions : prescribed_conditions(0)
    pmass = typeof(point_masses) <: AbstractDict ? point_masses : point_masses(0)

    expanded_system_mass_matrix!(jacob, gamma, indices, two_dimensional, force_scaling, assembly, pcond, pmass)

    return jacob
end

"""
    expanded_system_mass_matrix!(jacob, indices, two_dimensional, force_scaling,  assembly, prescribed_conditions,
        point_masses)

Calculate the jacobian of the residual expressions with respect to the state rates.
"""
function expanded_system_mass_matrix!(jacob, indices, two_dimensional, force_scaling, assembly,
    prescribed_conditions, point_masses)

    jacob .= 0

    gamma = 1

    expanded_system_mass_matrix!(jacob, gamma, indices, two_dimensional, force_scaling, assembly,
        prescribed_conditions, point_masses)

    return jacob
end

"""
    expanded_system_mass_matrix!(jacob, gamma, indices, two_dimensional, force_scaling, assembly,
        prescribed_conditions, point_masses)

Calculate the jacobian of the residual expressions with respect to the state rates and
add the result multiplied by `gamma` to `jacob`.
"""
function expanded_system_mass_matrix!(jacob, gamma, indices, two_dimensional, force_scaling, assembly,
    prescribed_conditions, point_masses)

    for ipoint = 1:length(assembly.points)
        expanded_mass_matrix_point_jacobian!(jacob, gamma, indices, two_dimensional,
            force_scaling, assembly, ipoint, prescribed_conditions, point_masses)
    end

    for ielem = 1:length(assembly.elements)
        expanded_mass_matrix_element_jacobian!(jacob, gamma, indices, two_dimensional,
            force_scaling, assembly, ielem, prescribed_conditions)
    end

    return jacob
end

"""
    two_dimensional_residual!(resid, x)

Modify the residual to constrain the results of an analysis to the x-y plane.
"""
function two_dimensional_residual!(resid, x)

    for (irow, icol) in zip(1:6:length(x), 1:6:length(x))
        resid[irow+2] = x[icol+2] # constrain linear component in z-direction to be zero
        resid[irow+3] = x[icol+3] # constrain angular component in x-direction to be zero
        resid[irow+4] = x[icol+4] # constrain angular component in y-direction to be zero
    end

    return resid
end

"""
    two_dimensional_jacobian!(jacob, x)

Modify the jacobian to constrain the results of an analysis to the x-y plane.
"""
function two_dimensional_jacobian!(jacob, x)

    for (irow, icol) in zip(1:6:length(x), 1:6:length(x))
        # constrain linear component in z-direction to be zero
        jacob[irow+2,:] .= 0
        jacob[irow+2,icol+2] = 1
        # constrain angular component in x-direction to be zero
        jacob[irow+3,:] .= 0
        jacob[irow+3,icol+3] = 1
        # constrain angular component in y-direction to be zero
        jacob[irow+4,:] .= 0
        jacob[irow+4,icol+4] = 1
    end

    return jacob
end