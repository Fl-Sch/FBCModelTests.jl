
"""
    module ReportGenerators

Functions for generating FROG report data and metadata file contents.
"""
module ReportGenerators

using ..FROG: FROGReactionReport, FROGObjectiveReport, FROGMetadata, FROGReportData

using ...FBCModelTests: FBCMT_VERSION

using COBREXA
using Distributed
using DocStringExtensions
using MD5
using SBML
using SHA

import InteractiveUtils

"""
$(TYPEDEF)

# Fields
$(TYPEDFIELDS)
"""
struct ResetObjective <: ModelWrapper
    model::MetabolicModel
    objective::SparseVec
end

COBREXA.unwrap_model(x::ResetObjective) = x.model
COBREXA.objective(x::ResetObjective) = x.objective

"""
$(TYPEDSIGNATURES)

Generate a [`FROGObjectiveReport`](@ref) containing the reproducibility data
for a single objective in the SBML model.
"""
function frog_objective_report(
    sbml_model::SBMLModel,
    objective::String;
    optimizer,
    workers,
)::FROGObjectiveReport
    @info "Creating report for objective $objective ..."
    # this prevents the default SBMLModel fireworks in case there's multiple objectives
    model = ResetObjective(sbml_model, SBML.fbc_flux_objective(sbml_model.sbml, objective))

    # run the first FBA
    @info "Finding model objective value ..."
    solved_model = flux_balance_analysis(model, optimizer)
    obj = solved_objective_value(solved_model)

    fvas = if isnothing(obj)
        @warn "Model does not have a feasible solution, skipping FVA."
        zeros(0, 2)
    else
        @info "Optimal solution found." obj
        @info "Calculating model variability ..."
        flux_variability_analysis(
            model,
            optimizer;
            bounds = objective_bounds(1.0),
            optimal_objective_value = obj,
            workers = workers,
        )
    end

    @info "Calculating gene knockouts ..."
    gids = genes(model)
    gs = screen(
        model,
        args = tuple.(gids),
        analysis = (m, gene) -> solved_objective_value(
            flux_balance_analysis(m, optimizer, modifications = [knockout(gene)]),
        ),
        workers = workers,
    )

    @info "Calculating reaction knockouts ..."
    rids = reactions(model)
    rs = screen(
        model,
        args = tuple.(rids),
        analysis = (m, rid) -> solved_objective_value(
            flux_balance_analysis(
                m,
                optimizer,
                modifications = [change_constraint(rid, lb = 0.0, ub = 0.0)],
            ),
        ),
        workers = workers,
    )

    @info "Objective $objective done."
    return FROGObjectiveReport(
        optimum = obj,
        reactions = Dict(
            rid => FROGReactionReport(
                flux = flx,
                variability_min = vmin,
                variability_max = vmax,
                deletion = ko,
            ) for (rid, flx, vmin, vmax, ko) in
            zip(rids, flux_vector(model, solved_model), fvas[:, 1], fvas[:, 2], rs)
        ),
        gene_deletions = Dict(gids .=> gs),
    )
end

"""
$(TYPEDSIGNATURES)

Generate [`FROGReportData`](@ref) for a model.
"""
generate_report_data(model::SBMLModel; optimizer, workers = [Distributed.myid()]) = Dict([
    objective => frog_objective_report(model, objective; optimizer, workers) for
    (objective, _) in model.sbml.objectives
])

"""
$(TYPEDSIGNATURES)
"""
generate_metadata(filename::String; optimizer, basefilename::String = basename(filename)) =
    FROGMetadata(
        "software.name" => "FBCModelTests.jl",
        "software.version" => string(FBCMT_VERSION),
        "software.url" => "https://github.com/LCSB-BioCore/FBCModelTests.jl/",
        "environment" => begin
            x = IOBuffer()
            InteractiveUtils.versioninfo(x)
            replace(String(take!(x)), r"\n *" => " ")
        end,
        "model.filename" => basefilename,
        "model.md5" => bytes2hex(open(f -> md5(f), filename, "r")),
        "model.sha256" => bytes2hex(open(f -> sha256(f), filename, "r")),
        "solver.name" => "COBREXA.jl $COBREXA_VERSION ($(COBREXA.JuMP.MOI.get(optimizer(), COBREXA.JuMP.MOI.SolverName())))",
    )

end

"""
    module ReportTests

Function for testing the compatibility of FROG report data.
"""
module ReportTests

using ..FROG: FROGReportData, FROGMetadata
using ...FBCModelTests: test_dicts

using Test, DocStringExtensions

"""
$(TYPEDSIGNATURES)
"""
function test_report_compatibility(
    a::FROGReportData,
    b::FROGReportData;
    absolute_tolerance = 1e-6,
    relative_tolerance = 1e-4,
)
    intol(a, b) =
        (isnothing(a) && isnothing(b)) || (
            !isnothing(a) &&
            !isnothing(b) &&
            abs(a - b) <= absolute_tolerance &&
            (
                (a * b > 0) && abs(a * (1 + relative_tolerance)) >= abs(b) ||
                abs(b * (1 + relative_tolerance)) >= abs(a)
            )
        )

    @testset "Comparing objectives" begin
        test_dicts(
            (_, a, b) -> begin
                @test intol(a.optimum, b.optimum)
                @testset "Reactions" begin
                    test_dicts(
                        (_, a, b) -> begin
                            @test intol(a.flux, b.flux)
                            @test intol(a.variability_min, b.variability_min)
                            @test intol(a.variability_max, b.variability_max)
                            @test intol(a.deletion, b.deletion)
                        end,
                        a.reactions,
                        b.reactions,
                    )
                end
                @testset "Gene deletions" begin
                    test_dicts(
                        (_, a, b) -> begin
                            @test intol(a, b)
                        end,
                        a.gene_deletions,
                        b.gene_deletions,
                    )
                end
            end,
            a,
            b,
        )
    end
end

"""
$(TYPEDSIGNATURES)
"""
function test_metadata_compatibility(a::FROGMetadata, b::FROGMetadata)
    for k in ["model.filename", "model.md5"]
        @testset "$k is present" begin
            @test haskey(a, k)
            @test haskey(b, k)
        end
    end

    for k in ["model.filename", "model.md5", "model.sha256"]
        if haskey(a, k) && haskey(b, k)
            @testset "$k matches" begin
                @test a[k] == b[k]
            end
        end
    end
end

end
