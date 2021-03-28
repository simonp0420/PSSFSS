module PSSFSS

if isdefined(Base, :Experimental) && isdefined(Base.Experimental, Symbol("@optlevel"))
    @eval Base.Experimental.@optlevel 3
end


using Reexport
using Dates: now
using DelimitedFiles: writedlm
using Printf: @sprintf
using LinearAlgebra: ×, norm, ⋅, factorize
using StaticArrays: MVector, MArray, @SVector
using Unitful: ustrip, @u_str
using Logging: with_logger
using ProgressMeter

include("Constants.jl")
include("Log.jl")
include("PSSFSSLen.jl")
include("Rings.jl")
include("Layers.jl")
include("Sheets.jl")
include("Meshsub.jl")
include("Elements.jl")
include("RWG.jl")
include("PGF.jl")
include("Zint.jl")
include("FillZY.jl")
include("GSMs.jl")
include("Modes.jl")
include("Outputs.jl")

using .Rings
using .Sheets: Sheet, RWGSheet
using .RWG: setup_rwg, rwgbfft!, RWGData
using .GSMs: GSM, cascade, cascade!, gsm_electric_gblock, gsm_magnetic_gblock,
             gsm_slab_interface, translate_gsm!, choose_gblocks, Gblock
using .FillZY: fillz, filly
using .Modes: zhatcross, choose_layer_modes!, setup_modes!
using .Constants: twopi, c₀, tdigits, dbmin
using .Log: pssfss_logger, @logfile
@reexport using .PSSFSSLen
@reexport using .Layers: Layer, TEorTM, TE, TM
@reexport using .Elements: rectstrip, polyring, meander, loadedcross, jerusalemcross, nullsheet
@reexport using .Outputs: @outputs, extract_result_file
using .Outputs: Result, append_result_data

export analyze


"""
    analyze(strata::Vector, flist, steering, outlist; logfile="pssfss.log", resultfile="pssfss.res")

Analyze a full FSS/PSS structure over a range of frequencies and steering angles/phasings.  
Generate output files as specified in `outlist`.

## Positional Arguments
- `strata`:  A vector of `Layer` and `Sheet` objects.

- `flist`: An iterable containing the analysis frequencies in GHz.

- `steering`: A length 2 `NamedTuple` containing as keys either

    - one of {`:phi` ,`:ϕ`} and one of {`:theta`, `:θ`}, or

    - one of {`:psi1` ,`:ψ₁`} and one of {`:psi2`, `:ψ₂`}
  
  The program will analyze while iterating over a triple loop over the two steering 
  parameters and frequency, with frequency in the innermost loop (i.e. varying the fastest).
  The steering parameter listed first will be in the outermost loop and will therefore
  vary most slowly.

- `outlist`:  A matrix with 2 columns.  The first column in each row is a string
  containing the name of the CSV file to write the output to.  The second entry in
  each row is a tuple generated by the `@outputs` macro of the `Outputs` module. The 
  contents of the specified file(s) will be updated as the program completes each analysis
  frequency.

## Keyword Arguments
- `logfile`:  A string containing the name of the log file to which timing and other 
  information about the run is written. Defaults to `"pssfss.log"`.
  If this file already exists, it will be overwritten.

- `resultfile`:  A string containing the name of the results file. Defaults to `pssfss.res`.
  If this file already exists, it will be overwritten.  It is a binary
  file that contains information (including the generalized scattering matrix) from 
  the analysis performed for each scan condition and frequency. The result file can be
  post-processed to produce similar or additional outputs that were requested at run time
  via the `outlist` argument.
"""
function analyze(strata, flist, steering, outlist; logfile="pssfss.log", resultfile="pssfss.res")
    with_logger(pssfss_logger(logfile)) do 
        _analyze(strata, flist, steering, outlist, resultfile)
    end
end

function _analyze(strata, flist, steering, outlist, resultfile)
    ncount = 0 # Number of analyses performed
    ntotal = length(flist) * length(steering[1]) * length(steering[2])
    progress = Progress(ntotal,1)
    isfile(resultfile) && rm(resultfile)
    date, clock = split(string(now()),'T')
    @logfile "\n\nStarting PSSFSS analysis on $(date) at $(clock)\n\n"
    check_inputs(strata, flist, steering, outlist)
    k0min, k0max = twopi*1e9/c₀ .* extrema(flist)
    gbls = choose_gblocks(strata, k0min)
    gsm_save = Vector{GSM}(undef, length(gbls)) # Storage for reusable GSMs
    choose_layer_modes!(strata, gbls, k0max, dbmin)
    layers::Vector{Layer} = [s for s in strata if s isa Layer]
    sheets::Vector{RWGSheet} = [s for s in strata if s isa Sheet]
    (gbldup,junc) = get_gbldup(gbls, layers, sheets, strata)
    usi = unique_indices(sheets)
    rwgdat::Vector{RWGData} = [setup_rwg(sheet) for sheet in sheets]
    report_layers_sheets(strata, rwgdat, usi)
    uvec::Vector{Float64} = map(sheets) do sh  # Green's function smoothing factors
        sh.style == "NULL" && (return 0.0)
        ufactor = 0.5 * ustrip(Float64, sh.units, 1u"m")
        ufactor * max(norm(sh.β₁), norm(sh.β₂))
    end
    # Begin analysis loops over steering angles and frequency
    firstoutput = true
    for stout in steering[1], stin in steering[2]
        steer = getsttuple(steering, stout, stin)
        if keys(steer)[1] == :ψ₁
            ψ₁, ψ₂ = steer # radians
            upm::Float64 = ustrip(Float64, sheets[1].units, 1u"m")
            β₁, β₂ = sheets[1].β₁*upm, sheets[1].β₂*upm
            β⃗₀₀ = (ψ₁*β₁ + ψ₂*β₂) / twopi # Eq. (2.13b)
        else
            θ, ϕ = steer # degrees
            st = sind(θ)
            sp, cp = sincosd(ϕ)
        end
        @logfile "Beginning $(steer)"
        for fghz in flist
            @logfile "  $(fghz) GHz"
            t_freq = time()
            k0 = twopi*fghz*1e9/c₀
            if keys(steer)[1] == :θ
                k1 = k0 * sqrt(real(layers[1].ϵᵣ * layers[1].μᵣ))
                β⃗₀₀ = @SVector([k1*st*cp, k1*st*sp])
            end
            setup_modes!.(layers, k0, Ref(β⃗₀₀))
            if !(angle(layers[begin].γ[1]) ≈ angle(layers[end].γ[1]) ≈ π/2)
                @logfile "  Skipping $(fghz) GHz due to cutoff principal modes in ambient medium"
                continue
            end
            # Initialize overall GSM and propagate it through layer 1's width:
            n1 = length(layers[1].P)
            gsma = GSM(n1,n1)
            gsmc = deepcopy(gsma)
            cascade!(gsma, layers[1])
            for (ig,gbl) in pairs(gbls) # Walk through the Gblocks
                i1 = first(gbl.rng) # Index of layer to left of Gblock
                i2 = 1 + last(gbl.rng) # Index of layer to right of Gblock
                i_junc = gbl.j # junction where FSS is located, or 0 if no sheet
                i_sheet = i_junc == 0 ? 0 : junc[i_junc]
                if i_sheet ≠ 0
                    if gbldup[ig] > 0
                        gsmb = deepcopy(gsm_save[gbldup[ig]]) # Use previously calculated GSM
                    else
                        region = @view layers[i1:i2]
                        sheet = sheets[i_sheet]
                        s = gbl.j - i1 + 1 # sheet interface location within `region`
                        if sheet.class == 'J'
                            gsmb = calculate_jtype_gsm(region, sheet, uvec[i_sheet], 
                                                       rwgdat[i_sheet], s, k0, β⃗₀₀, i_sheet)              
                        elseif sheet.class == 'M'
                            gsmb = calculate_mtype_gsm(region, sheet, uvec[i_sheet],
                                                       rwgdat[i_sheet], s, k0, β⃗₀₀, i_sheet)
                        else
                            error("Illegal sheet class: $(sheet.class)")
                        end

                        gbldup[ig] < 0 && (gsm_save[ig] = gsmb)          
                    end
                    # Apply translations if requested:
                    if sheet.dx ≠ 0 || sheet.dy ≠ 0
                        upm = ustrip(Float64, sheet.units, 1u"m")
                        dx = sheet.dx / upm
                        dy = sheet.dy / upm
                        translate_gsm!(gsmb, dx, dy, first(region), last(region))
                    end

                else # no sheet
                    @assert i2 - i1 == 1
                    gsmb = gsm_slab_interface(layers[i1], layers[i2], k0)
                end
                gsmc = cascade(gsma, gsmb)
                cascade!(gsmc, layers[i2])
                gsma = gsmc 
            end # Gblock loop
            t_freq = round(time()-t_freq, digits=tdigits)
            @logfile "  $(t_freq) seconds total at $(fghz) GHz"

            result = Result(gsmc, steer, β⃗₀₀, fghz, layers[1].ϵᵣ, layers[1].μᵣ, 
            layers[1].β₁, layers[1].β₂, layers[end].ϵᵣ, layers[end].μᵣ, 
            layers[end].β₁, layers[end].β₂)

            ncount += 1
            # Write to output files
            append_result_data(resultfile,string(ncount),result)
            for row in eachrow(outlist)
                if firstoutput
                    open(row[1], "w") do io
                        writedlm(io, permutedims([r.label for r in row[2]]), ',')
                    end
                    firstoutput = false
                end
                open(row[1], "a") do io
                    writedlm(io, permutedims([r(result) for r in row[2]]), ',')
                end
            end
            next!(progress) # Bump progress meter
        end # Frequency loop
    end # steering angle loop

    date, clock = split(string(now()),'T')
    @logfile "\n\n PSSFSS analysis exiting on $(date) at $(clock)\n\n"
    return nothing
end # function



"""
    calculate_jtype_gsm(layers, sheet::RWGSheet, u::Real, rwgdat::RWGData, s::Int, k0, k⃗inc, is_global::Int) -> gsm

Compute the generalized scattering matrix for a sheet of class `'J'`.

### Input Arguments

- `layers`: An iterable of `Layer` instances containing the layers for the `Gblock`
    associated with the `sheet` under consideration.
- `sheet`:  A sheet of class `'J'` for which the GSM is desired.
- `u`: The Green's function smoothing parameter for the `sheet`.
- `rwgdat`: The `RWGData` object associated with the `sheet` argument.
- `s`: The interface number within `layers` at which the sheet is located.
- `k0`: The free-space wavenumber in radians/meter.
- `k⃗inc`: A 2-vector containing the incident field wave vector x and y components. Note
    that by the phase match condition this vector is the same for all layers in the entire FSS
    structure.
- `is_global`: The global sheet index for the `sheet` argument within the global list of sheets.

### Return Value

- `gsm::GSM`  The full GSM for the GBlock including incident fields and scattered fields due
    to currents induced on the sheet surface.
"""
function calculate_jtype_gsm(layers, sheet::RWGSheet, u::Real,
                                 rwgdat::RWGData, s::Int, k0, k⃗inc, is_global::Int)
    one_meter = ustrip(Float64, sheet.units, 1u"m")
    area = norm(sheet.s₁ × sheet.s₂) / one_meter^2 # Unit cell area (m^2).
    acf = MVector(0.0,0.0)
    nmodesmax = max(length(layers[begin].P), length(layers[end].P)) 
    nbf = size(rwgdat.bfe,2) # Number of basis functions
    bfftstore = zeros(MArray{Tuple{2},ComplexF64,1,2}, (nbf, 2, nmodesmax))

    # Compute area correction factors for the mode normalization constants of 
    # the two end regions:
    for (i,l) in enumerate(@view layers[[begin,end]])
      area_i = twopi * twopi / norm(l.β₁ × l.β₂)
      acf[i] = √(area_i / area)
    end

    # Set up the partial GSM due to incident field
    (gsm, tlgfvi, vincs) = gsm_electric_gblock(layers, s, k0)
    if sheet.style == "NULL"
        return gsm
    end

    # Calculate the scattered field partial scattering matrix of the 
    # FSS sheet at this junction. Then add it to GSM already computed 
    # for the dielectric discontinuity...
    
    #  Fill the interaction matrix for the current sheet:
    t_temp = time()
    ψ₁ = k⃗inc ⋅ sheet.s₁ / one_meter
    ψ₂ = k⃗inc ⋅ sheet.s₂ / one_meter
    @logfile "    Beginning matrix fill for sheet $(is_global)"
    zmat = fillz(k0,u,layers,s,ψ₁,ψ₂,sheet,rwgdat)
    t_fill = round(time() - t_temp, digits=tdigits)
    @logfile "      $(t_fill) seconds total matrix fill time for sheet $(is_global)"
    # Factor the matrix:
    t_temp = time()
    zmatf = factorize(zmat)
    t_factor = round(time() - t_temp, digits=tdigits)
    @logfile "      $(t_factor) seconds to factor matrix for sheet $(is_global)"
    t_temp = time()
    # Compute and store the basis function Fourier transforms:
    i_ft = 0
    for (sr,l) in enumerate(@view layers[[begin,end]]) # loop over possible source regions
        for qp = 1:length(l.P) 
            kvec = l.β[qp]
            # If desired F.T. has already been computed, then copy it.
            if qp > 1 && kvec ≈ l.β[qp-1]
                bfftstore[:,sr,qp] = bfftstore[:,sr,qp-1] 
                continue
            end
            if sr == 2 && length(layers[1].β) ≥ qp && kvec ≈ layers[1].β[qp]
                bfftstore[:,2,qp] = bfftstore[:,1,qp] 
                continue
            end
            bfft = @view bfftstore[:,sr,qp]
            rwgbfft!(bfft, rwgdat, sheet, kvec, ψ₁, ψ₂) # Otherwise, compute from scratch
            i_ft += 1
        end
    end
    t_fft = round(time() - t_temp, digits=tdigits)
    @logfile "      $(t_fft) seconds for basis function Fourier transforms at $(i_ft) points"
    nsolve = 0
    t_extract = 0.0
    i_extract = 0
    t_solve = 0.0
    for (sr,ls) in enumerate(@view layers[[begin,end]]) # Loop over source regions
        for qp in 1:length(ls.P) # Loop over srce reg modes
            # Incident field for source layer in absence of the FSS sheet:
            sourcevec = vincs[qp,sr] * ls.c[qp] * acf[sr] * ls.tvec[qp]
            # Compute generalized voltage vector:
            imat = [b ⋅ sourcevec for b in bfftstore[:,sr,qp]] # Eq. (7.39)
            # Solve the matrix equation
            t_solve1 = time()
            imat = zmatf \ imat
            t_solve2 = time()
            t_solve += t_solve2 - t_solve1
            nsolve += 1
            t_extract1 = time()
            for (or,lo) in enumerate(@view layers[[begin,end]]) # Loop over obs. regions
                smat = gsm[or,sr]
                for q in 1:length(lo.P)  # Loop obs. regn modes
                    # Extract partial scattering parameter due to scattered fields...
                    FTJ = sum((imat[n] * bfftstore[n,or,q] for n in 1:nbf)) # FT of total current
                    smat[q,qp] -= (lo.tvec[q] ⋅ FTJ) * (tlgfvi[q,or] / 
                                                (lo.c[q] * acf[or] * area)) # Eq (6.18)
                    i_extract += 1
                end
            end
            t_extract2 = time()
            t_extract = t_extract + (t_extract2 - t_extract1)
        end
    end
    @logfile "      $(round(t_extract,digits=tdigits)) seconds to extract $(i_extract) GSM entries"
    return gsm
end  

"""
    calculate_mtype_gsm(layers, sheet::RWGSheet, u::Real, rwgdat::RWGData, s::Int, k⃗inc, is_global::Int) -> gsm

Compute the generalized scattering matrix for a sheet of class `'M'`.

### Input Arguments

- `layers`: An iterable of `Layer` instances containing the layers for the `Gblock`
    associated with the `sheet` under consideration.
- `sheet`:  A sheet of class `'M'` for which the GSM is desired.
- `u`: The Green's function smoothing parameter for the `sheet`.
- `rwgdat`: The `RWGData` object associated with the `sheet` argument.
- `s`: The interface number within `layers` at which the sheet is located.
- `k0`: The free-space wavenumber in radians/meter.
- `k⃗inc`: A 2-vector containing the incident field wave vector x and y components. Note
    that by the phase match condition this vector is the same for all layers in the entire FSS
    structure.
- `is_global`: The global sheet index for the `sheet` argument within the global list of sheets.

### Return Value

- `gsm::GSM`  The full GSM for the GBlock including incident fields and scattered fields due
    to magnetic currents induced in the gaps on the sheet surface.
"""
function calculate_mtype_gsm(layers, sheet::RWGSheet, u::Real,
                                 rwgdat::RWGData, s::Int, k0, k⃗inc, is_global::Int)
    one_meter = ustrip(Float64, sheet.units, 1u"m")
    area = norm(sheet.s₁ × sheet.s₂) / one_meter^2 # Unit cell area (m^2).
    acf = MVector(0.0,0.0)
    nmodesmax = max(length(layers[begin].P), length(layers[end].P)) 
    nbf = size(rwgdat.bfe,2) # Number of basis functions
    bfftstore = zeros(MArray{Tuple{2},ComplexF64,1,2}, (nbf, 2, nmodesmax))

    # Compute area correction factors for the mode normalization constants of 
    # the two end regions:
    for (i,l) in enumerate(@view layers[[begin,end]])
      area_i = twopi * twopi / norm(l.β₁ × l.β₂)
      acf[i] = √(area_i / area)
    end

    # Set up the partial GSM due to incident field
    (gsm, tlgfiv, iincs) = gsm_magnetic_gblock(layers, s, k0)
    if sheet.style == "NULL"
        return gsm
    end

    # Calculate the scattered field partial scattering matrix of the 
    # FSS sheet at this junction. Then add it to GSM already computed 
    # for the dielectric discontinuity...
    
    #  Fill the interaction matrix for the current sheet:
    t_temp = time()
    ψ₁ = k⃗inc ⋅ sheet.s₁ / one_meter
    ψ₂ = k⃗inc ⋅ sheet.s₂ / one_meter
    @logfile "    Beginning matrix fill for sheet $(is_global)"
    ymat = filly(k0,u,layers,s,ψ₁,ψ₂,sheet,rwgdat)
    t_fill = round(time() - t_temp, digits=tdigits)
    @logfile "      $(t_fill) seconds total matrix fill time for sheet $(is_global)"
    # Factor the matrix:
    t_temp = time()
    ymatf = factorize(ymat)
    t_factor = round(time() - t_temp, digits=tdigits)
    @logfile "      $(t_factor) seconds to factor matrix for sheet $(is_global)"
    t_temp = time()
    # Compute and store the basis function Fourier transforms:
    i_ft = 0
    for (sr,l) in enumerate(@view layers[[begin,end]]) # loop over possible source regions
        for qp = 1:length(l.P) 
            kvec = l.β[qp]
            # If desired F.T. has already been computed, then copy it.
            if qp > 1 && kvec ≈ l.β[qp-1]
                bfftstore[:,sr,qp] = bfftstore[:,sr,qp-1] 
                continue
            end
            if sr == 2 && length(layers[1].β) ≥ qp && kvec ≈ layers[1].β[qp]
                bfftstore[:,2,qp] = bfftstore[:,1,qp] 
                continue
            end
            bfft = @view bfftstore[:,sr,qp]
            rwgbfft!(bfft, rwgdat, sheet, kvec, ψ₁, ψ₂) # Otherwise, compute from scratch
            i_ft += 1
        end
    end
    t_fft = round(time() - t_temp, digits=tdigits)
    @logfile "      $(t_fft) seconds for basis function Fourier transforms at $(i_ft) points"
    nsolve = 0
    t_extract = 0.0
    t_solve = 0.0
    i_extract = 0
    σ = -1
    for (sr,ls) in enumerate(@view layers[[begin,end]]) # Loop over source regions
        σ *= -1 # 1 for sr == 1, and -1 for sr == 2
        for qp in 1:length(ls.P) # Loop over srce reg modes
            # Incident field for Region sr (Eq. (7.64))
            sourcevec = iincs[qp,sr] * ls.c[qp] * ls.Y[qp] * zhatcross(ls.tvec[qp])
            # Compute generalized current vector:
            vmat = [b ⋅ sourcevec for b in bfftstore[:,sr,qp]] # Eq. (7.64)
            # Solve the matrix equation
            t_solve1 = time()
            vmat = ymatf \ vmat
            t_solve2 = time()
            t_solve += t_solve2 - t_solve1
            nsolve += 1
            t_extract1 = time()
            for (or,lo) in enumerate(@view layers[[begin,end]]) # Loop over obs. regions
                smat = gsm[or,sr]
                for q in 1:length(lo.P)  # Loop obs. regn. modes
                    # Extract partial scattering parameter due to scattered fields...
                    FTM = sum((vmat[n] * bfftstore[n,or,q] for n in 1:nbf)) # FT of total mag. current
                    smat[q,qp] += (zhatcross(lo.tvec[q]) ⋅ FTM) * 
                                        (σ * tlgfiv[q,or] * lo.c[q]) # Eq. (6.37)
                    i_extract += 1
                end
            end
            t_extract2 = time()
            t_extract += t_extract2 - t_extract1
        end
    end
    @logfile "      $(t_extract) seconds to extract $(i_extract) GSM entries"
    return gsm
end


"""
    getsttuple(steering::NamedTuple, stout::Real, stin::Real) -> NamedTuple

Return a named tuple either of the form `(θ = θ, ϕ = ϕ)` or `(ψ₁ = ψ₁, ψ₂ = ψ₂)` that serves
to define the current steering situation. Actually, the input field names can be spelled out in
English as `:theta`, `:phi`, `:psi1`, and `:psi2`.

### Arguments

- `steering`: A named 2-tuple with fieldnames either (`:ψ₁` and `ψ₂`) or (`:θ` and `:ϕ`) 
  (or their spelled-out English versions as detailed above), either of which
  could be listed in either order.  The order is significant in that the first member of the pair
  defines the outer steering loop.  

- `stout` and `stin`: These are the current values of the outer and inner steering variables,
  respectively.
"""
function getsttuple(steering::NamedTuple, stout::Real, stin::Real)
    stin, stout = float.((stin,stout))
    if keys(steering)[1] ∈ (:phi, :ϕ)
        return (θ = stin, ϕ = stout)
    elseif keys(steering)[2] ∈ (:phi, :ϕ)
        return (θ = stout, ϕ = stin)
    elseif keys(steering)[1] ∈ (:psi1, :ψ₁)
        return (ψ₁ = stout, ψ₂ = stin)
    else
        return (ψ₁ = stin, ψ₂ = stout)
    end
end

function check_inputs(strata, flist, steering, outlist)
    # Check that input and output media are lossless
    # Check that ψ₁ and ψ₂ are not specified when there are no nonnull sheets
    return
end


"""
    unique_indices(v::Vector)

Return a vector `ui` of the same length as `v`. 
`ui[k]` contains the smallest `i` such that 'i ≤ k` and `ui[i] === ui[k]`
"""
function unique_indices(v::Vector)
    n = length(v)
    ui = collect(1:n)
    for io in 1:n-1
        ui[io] ≠ io && continue
        for it in io+1:n
            ui[it] ≠ it && continue
            v[io] === v[it]  && (ui[it] = io)
        end
    end
    return ui
end

"""
    get_gbldup(gbls::Vector{Gblock}, layers::Vector{Layer}, sheets::Vector{Sheet}, strata::Vector)
    -> (gbldup, junc)

Return `gbldup::Vector{Int}` of the same length as `gbls`. 
`gbldup[k]` contains `0` for an ordinary Gblock.  `gbldup[k] == -1` means that
`gbls[k]` is the first occurence of a repeated Gblock and that its GSM should be 
saved for reuse.  `gbldup[k] == i` where `0<i<k` means that `gbls[k]` is identical
to `gbls[i]` and they can both use the same GSM.
Two `Gblock`s are considered identical if they 

1. Contain identical (`===`) `Sheet` objects at the same location within the block.
2. Comprise the same number of dielectric layers with identical widths analyzed
   electrical characteristics.
3. Are embedded within similar adjacent dielectric layers, having identical electrical
   properties and numbers of modes.

`junc::Vector{Int}` is has length `length(Layers)-1`. `junc[i]`` is the sheet number 
present at dielectric interface `i`, or `0` if no sheet is present there.
"""
function get_gbldup(gbls::Vector{Gblock}, layers::Vector{Layer}, sheets::Vector{<:Sheet}, strata)
    gbldup = zeros(Int, length(gbls))
    issheet = map(x -> x isa Sheet, strata)
    islayer = map(x -> x isa Layer, strata)
    sint = cumsum(islayer)[issheet] # sint[k] contains dielectric interface number of k'th sheet 
    junc = zeros(Int, length(layers)-1)
    junc[sint] = 1:length(sheets) #  junc[i] is the sheet number present at interface i, or 0 if no sheet is there

    for (g1,gbl1) in pairs(gbls)
        (gbldup[g1] ≠ 0 || gbl1.j == 0) && continue
        j1, rng1 = gbl1.j, gbl1.rng
        n1 = length(layers[first(rng1)].P) # modes at left side
        n2 = length(layers[last(rng1)+1].P) # modes at right side
        # Examine succeeding Gblocks to see if they match:
        for g2 in g1+1:length(gbls)
            gbl2 = gbls[g2]
            rng2 = gbl2.rng
            j2 = gbl2.j
            (gbldup[g2] ≠ 0 || j2 == 0) && continue
            sheets[junc[j1]] === sheets[junc[j2]] || continue
            last(rng1)-j1 ≠ last(rng2)-j2 && continue 
            # Check that layers within blocks gbl1 and gbl2 are identical:
            length(rng1) ≠ length(rng2) && continue
            n1 ≠ length(layers[first(rng2)].P) && continue
            n2 ≠ length(layers[1+last(rng2)].P) && continue
            all(zip(rng1,rng2)) do (i1,i2)
                i1 == first(rng1) && (return true)
                layers[i1] == layers[i2]
            end || continue
            # If we made it to here, the two Gblocks are identical:
            gbldup[g1] = -1  # Indicate that GSM of Gblock g1 is to be saved
            gbldup[g2] = g1  # GSM of Gblock g2 is obtained from saved GSM of block g1
        end
    end
    return (gbldup, junc)
end # function
    

function report_layers_sheets(strata, rwgdat, usi)
    layers = [s for s in strata if s isa Layer]
    sheets = [s for s in strata if s isa Sheet]
    @logfile "Dielectric layer information... \n"
    @logfile " Layer  Width  units  epsr   tandel   mur  mtandel modes  beta1x  beta1y  beta2x  beta2y"
    @logfile " ----- ------------- ------- ------ ------- ------ ----- ------- ------- ------- -------"
    js = 0 # sheet counter 
    jl = 0 # layer counter
    for s in strata
        if s isa Layer
            l = s
            jl += 1
            eps = real(l.ϵᵣ)
            tandel = -imag(l.ϵᵣ) / eps
            mu = real(l.μᵣ)
            mtandel = -imag(l.μᵣ) / mu 
            nmode = length(l.P)
            units = string(unit(l.user_width))
            units == "inch" && (units = "in")
            uw_unitless = ustrip(l.user_width)
            str = @sprintf(" %5i %9.4f %3s %7.2f %6.4f %7.2f %6.4f %5i %7.1f %7.1f %7.1f %7.1f",
              jl,uw_unitless, units, eps, tandel, mu, mtandel, nmode, l.β₁[1], l.β₁[2], 
              l.β₂[1], l.β₂[2])
            @logfile "$str"
        else
            # A Sheet object
            js += 1
            om = ustrip(Float64, s.units, 1.0u"m")
            str = @sprintf(
                " ==================  Sheet %3i  ======================== %7.1f %7.1f %7.1f %7.1f",
                usi[js], s.β₁[1] * om, s.β₁[2] * om, s.β₂[1] * om, s.β₂[2] * om)
            @logfile "$str"
        end
    end
  
    @logfile "\n\n\nPSS/FSS sheet information...\n"
    @logfile "Sheet  Loc         Style      Rot  J/M Faces Edges Nodes Unknowns  NUFP"
    @logfile "-----  ---  ---------------- ----- --- ----- ----- ----- -------- ------"
    
    js = jl = 0
    for s in strata
        if s isa Layer
            jl += 1
            continue
        end
        js += 1
        str = @sprintf("%4i   %3i  %16s %5.1f  %1s  %5i %5i %5i  %6i %7i",
             usi[js], jl, s.style, s.rot, s.class, size(s.fe,2), length(s.e1), 
             length(s.ρ), size(rwgdat[js].bfe,2), length(rwgdat[js].ufp2fp))
        @logfile "$str"
    end
    @logfile "\n\n"
    nothing
end


end # module
