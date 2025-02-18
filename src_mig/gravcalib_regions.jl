using CSV, DataFrames, DelimitedFiles, ExcelFiles
using Plots, VegaLite, FileIO, VegaDatasets, FilePaths
using Statistics, Query


############################################ Read data on gravity-derived migration ##############################################
# We use the migration flow data from Azose and Raftery (2018) as presented in Abel and Cohen (2019)
gravity_endo = CSV.read(joinpath(@__DIR__,"../results/gravity/gravity_endo.csv"), DataFrame)

# gravity_endo has data in log. We transform it back.
data = gravity_endo[:,[:year,:orig,:dest,:flow_AzoseRaftery,:pop_orig,:pop_dest,:ypc_orig,:ypc_dest]]
for name in [:flow_AzoseRaftery,:pop_orig,:pop_dest,:ypc_orig,:ypc_dest,]
    data[!,name] = [exp(data[!,name][i]) for i in 1:size(data, 1)]
end
data[!,:gdp_orig] = data[:,:pop_orig] .* data[:,:ypc_orig]
data[!,:gdp_dest] = data[:,:pop_dest] .* data[:,:ypc_dest]

# Transpose to FUND region * region level. 
iso3c_fundregion = CSV.read("../input_data/iso3c_fundregion.csv", DataFrame)
data = join(data, rename(iso3c_fundregion, :fundregion => :originregion, :iso3c => :orig), on =:orig)
data = join(data, rename(iso3c_fundregion, :fundregion => :destinationregion, :iso3c => :dest), on =:dest)

data_reg = by(data, [:year,:originregion,:destinationregion], d->(migflow=sum(d.flow_AzoseRaftery),pop_o=sum(d.pop_orig),pop_d=sum(d.pop_dest),gdp_o=sum(d.gdp_orig),gdp_d=sum(d.gdp_dest)))

remcost = CSV.read(joinpath(@__DIR__,"../data_mig/remcost.csv"), DataFrame;header=false)
data_reg = join(data_reg, rename(remcost, :Column1=>:originregion,:Column2=>:destinationregion,:Column3=>:remcost),on=[:originregion,:destinationregion])

distance = CSV.read(joinpath(@__DIR__,"../data_mig/distance.csv"), DataFrame;header=false)
data_reg = join(data_reg, rename(distance, :Column1=>:originregion,:Column2=>:destinationregion,:Column3=>:distance),on=[:originregion,:destinationregion])

comofflang = CSV.read(joinpath(@__DIR__,"../data_mig/comofflang.csv"), DataFrame;header=false)
data_reg = join(data_reg, rename(comofflang, :Column1=>:originregion,:Column2=>:destinationregion,:Column3=>:comofflang),on=[:originregion,:destinationregion])

rho_fund_est = CSV.read(joinpath(@__DIR__,"../input_data/rho_fund_est.csv"), DataFrame)
data_reg = join(data_reg, rho_fund_est[:,union(1:2,13)], on=[:originregion,:destinationregion])

# Creating gdp per capita variables
data_reg[!,:ypc_o] = data_reg[!,:gdp_o] ./ data_reg[!,:pop_o]
data_reg[!,:ypc_d] = data_reg[!,:gdp_d] ./ data_reg[!,:pop_d]


###################################### Calibrate the gravity equation ##################################
# log transformation
logdata_reg = DataFrame(
    year = data_reg[!,:year], 
    originregion = data_reg[!,:originregion], 
    destinationregion = data_reg[!,:destinationregion], 
    exp_residual = data_reg[!,:exp_residual], 
    remcost = data_reg[!,:remcost],
    comofflang = data_reg[!,:comofflang]
)
for name in [:migflow, :pop_o, :pop_d, :ypc_o, :ypc_d, :distance]
    logdata_reg[!,name] = [log(data_reg[!,name][i]) for i in 1:size(logdata_reg, 1)]
end

# Remove rows with distance = 0 or flow = 0
gravity_reg = @from i in logdata_reg begin
    @where i.distance != -Inf && i.migflow != -Inf
    @select {i.year, i.originregion, i.destinationregion, i.migflow, i.pop_o, i.pop_d, i.ypc_o, i.ypc_d, i.distance, i.exp_residual, i.remcost, i.comofflang}
    @collect DataFrame
end

# Compute linear regression with FixedEffectModels package
gravity_reg.OrigCategorical = categorical(gravity_reg.originregion)
gravity_reg.DestCategorical = categorical(gravity_reg.destinationregion)
gravity_reg.YearCategorical = categorical(gravity_reg.year)

# Estimate the main gravity equation using residuals from remshare regression
rer1 = reg(gravity_reg, @formula(migflow ~ pop_o + pop_d + ypc_o + ypc_d + distance + exp_residual + remcost + comofflang + fe(YearCategorical)), Vcov.cluster(:OrigCategorical, :DestCategorical), save=true)
rer2 = reg(gravity_reg, @formula(migflow ~ pop_o + pop_d + ypc_o + ypc_d + distance + exp_residual + remcost + comofflang + fe(OrigCategorical) + fe(DestCategorical) + fe(YearCategorical)), Vcov.cluster(:OrigCategorical, :DestCategorical), save=true)

regtable(rer1, rer2; renderSettings = latexOutput(),regression_statistics=[:nobs, :r2, :r2_within])     

beta_reg = DataFrame(
    regtype = ["reg_reg_yfe","reg_reg_odyfe"],
    b1 = [0.676,1.226],       # pop_o
    b2 = [0.524,1.581],       # pop_d
    b4 = [0.895,0.429],       # ypc_o
    b5 = [1.427,0.473],       # ypc_d
    b7 = [-0.711,-0.680],       # distance
    b8 = [-0.293,-0.190],       # exp_residual
    b9 = [14.647,-1.379],       # remcost
    b10 = [2.183,0.504]     # comofflang
)

# Compute constant including year fixed effect as average of beta0 + yearFE
cst_reg_yfe = hcat(gravity_reg[:,Not([:OrigCategorical,:DestCategorical,:YearCategorical])], fe(rer1))
cst_reg_yfe[!,:constant] = cst_reg_yfe[!,:migflow] .- beta_reg[1,:b1] .* cst_reg_yfe[!,:pop_o] .- beta_reg[1,:b2] .* cst_reg_yfe[!,:pop_d] .- beta_reg[1,:b4] .* cst_reg_yfe[!,:ypc_o] .- beta_reg[1,:b5] .* cst_reg_yfe[!,:ypc_d] .- beta_reg[1,:b7] .* cst_reg_yfe[!,:distance] .- beta_reg[1,:b8] .* cst_reg_yfe[!,:exp_residual] .- beta_reg[1,:b9] .* cst_reg_yfe[!,:remcost] .- beta_reg[1,:b10] .* cst_reg_yfe[!,:comofflang]
constant_reg_yfe = mean(cst_reg_yfe[!,:constant])

cst_reg_odyfe = hcat(gravity_reg[:,Not([:OrigCategorical,:DestCategorical,:YearCategorical])], fe(rer2))
cst_reg_odyfe[!,:constant] = cst_reg_odyfe[!,:migflow] .- beta_reg[2,:b1] .* cst_reg_odyfe[!,:pop_o] .- beta_reg[2,:b2] .* cst_reg_odyfe[!,:pop_d] .- beta_reg[2,:b4] .* cst_reg_odyfe[!,:ypc_o] .- beta_reg[2,:b5] .* cst_reg_odyfe[!,:ypc_d] .- beta_reg[2,:b7] .* cst_reg_odyfe[!,:distance] .- beta_reg[2,:b8] .* cst_reg_odyfe[!,:exp_residual] .- beta_reg[2,:b9] .* cst_reg_odyfe[!,:remcost] .- beta_reg[2,:b10] .* cst_reg_odyfe[!,:comofflang] .- cst_reg_odyfe[!,:fe_OrigCategorical] .- cst_reg_odyfe[!,:fe_DestCategorical]
constant_reg_odyfe = mean(cst_reg_odyfe[!,:constant])

beta_reg[!,:b0] = [constant_reg_yfe,constant_reg_odyfe]       # constant

# Gather FE values
fe_reg_yfe = hcat(gravity_reg[:,[:year,:originregion,:destinationregion]], fe(rer1))
fe_reg_odyfe = hcat(gravity_reg[:,[:year,:originregion,:destinationregion]], fe(rer2))


CSV.write(joinpath(@__DIR__,"../results/gravity/beta_reg.csv"), beta_reg)

CSV.write(joinpath(@__DIR__,"../results/gravity/fe_reg_yfe.csv"), fe_reg_yfe)
CSV.write(joinpath(@__DIR__,"../results/gravity/fe_reg_odyfe.csv"), fe_reg_odyfe)

CSV.write(joinpath(@__DIR__,"../results/gravity/gravity_reg.csv"), gravity_reg)
