export AcquisitionData, kData, kdataSingleSlice, convertUndersampledData,
       weightData!, weightedData, unweightData!, unweightDataSquared!, changeEncodingSize2D

"""
 contains all relevant info for the aquired data.
 kdata is stored as a Array{Matrix{Float64}}, where
 each matrix contains data for one measurement
    (1.dim k-space nodes, 2. dim coils)
 The outer Array spans the following dimensions
 1. dim : echoes
 2. dim : slices
 (3. dim : repetitions)
"""
mutable struct AcquisitionData
  sequenceInfo::Dict{Symbol,Any}
  traj::Vector{Trajectory}
  kdata::Array{Matrix{ComplexF64},3}
  numEchoes::Int64
  numCoils::Int64
  numSlices::Int64
  numReps::Int64
  subsampleIndices::Vector{Array{Int64}}
  encodingSize::Vector{Int64}
  fov::Vector{Float64}
end

##############
# constructors
##############
function AcquisitionData(tr::T,kdata::Array{Matrix{ComplexF64},3}
                        ; seqInfo=Dict{Symbol,Any}()
                        , numCoils=1
                        , numEchoes=1
                        , numSlices=1
                        , numReps=1
                        , idx=nothing
                        , encodingSize=Int64[0,0,0]
                        , fov=Float64[0,0,0]
                        , kargs...) where T <: Union{Trajectory,Vector{Trajectory}}
  tr_vec = vec(tr)
  if idx != nothing
    subsampleIndices = idx
  else
    subsampleIndices = [collect(1:size(tr_vec[echo],2)) for echo=1:numEchoes]
  end

  return AcquisitionData(seqInfo,tr_vec,kdata,numEchoes,numCoils,numSlices,numReps,subsampleIndices,encodingSize,fov)
end

function Images.pixelspacing(acqData::AcquisitionData)
  return [1.0,1.0,1.0]*Unitful.mm
  #return fov./encodingSize*Unitful.mm  #TODO: all needs to be properly initialized
end

############
# trajectory
############
trajectory(acqData::AcquisitionData,i::Int64=1) = acqData.traj[i]

######################
# getting k-space data
######################

#
# return kdata for a given coil, echo and image slice
#
function kData(acqData::AcquisitionData, echo::Int64=1, coil::Int64=1, slice::Int64=1;rep::Int64=1)
  return acqData.kdata[echo,slice,rep][:,coil]
end

#
# return multi-echo-data for a given coil and image slice
#
function multiEchoData(acqData::AcquisitionData, coil::Int64, slice::Int64;rep::Int64=1)
  kdata = ComplexF64[]
  for echo=1:acqData.numEchoes
    append!(kdata,acqData.kdata[echo,slice,rep][:,coil])
  end
  return kdata
end

#
# return multi-coil-data for a given echo and image slice
#
function multiCoilData(acqData::AcquisitionData, echo::Int64, slice::Int64;rep::Int64=1)
  return vec(acqData.kdata[echo,slice,rep])
end

#
# return multi-coil-multi-echo-data for a given slice (for all coils and echoes)
#
function multiCoilMultiEchoData(acqData::AcquisitionData,slice::Int64;rep=1)
  kdata = ComplexF64
  for coil=1:acqData.numCoils
    for echo=1:acqData:numEchoes
      append!(kdata, acqData.kdata[echo,slice,rep][:,coil])
    end
  end
  return kdata
end

#
# return kdata for a given profile
#
function profileData(acqData::AcquisitionData, echo::Int64, slice::Int64, rep::Int, prof_tr::Int)
  tr = trajectory(acqData,echo)
  numProfiles, numSamp, numSlices = numProfiles(tr), numSamplePerProfile(tr), numSlices(tr)
  if dims(tr)==2 || numSlices==1
    kdata = reshape(multiCoilData(acqData,echo,slice;rep=rep),numSamp,numProfiles,acqData.numCoils)
    prof_data = kdata[:,prof_tr,:]
  else
    kdata = reshape(multiCoilData(acqData,echo,1,rep=rep),numSamp,numProfiles,numSlices,acqData.numCoils)
    prof_data = kdata[:,prof_tr,slice,:]
  end
  return prof_data
end

######################################
# utilities to convert and edit acqData
######################################
"""
 convert undersampled AcquisitionData, where only profiles contained in
 acqData.subsampleIndices are sampled,
 into a format where trajectories only contain the sampled profiles
"""
function convertUndersampledData(acqData::AcquisitionData)

  acqDataSub = deepcopy(acqData)

  # get number of nodes and reset idx
  numNodes = size(acqData.subsampleIndices,1)
  for echo=1:acqDataSub.numEchoes
    acqDataSub.subsampleIndices[echo] = collect(1:length(acqData.subsampleIndices[echo]))
  end

  # replace trajectories by Undersampled Trajectories
  for i = 1:acqData.numEchoes
    tr = trajectory(acqDataSub,i)
    # assume that coils and slices experience the same trajectory
    tr.nodes = tr.nodes[:,acqData.subsampleIndices[i]]
    tr.cartesian = false
  end

  return acqDataSub
end

##################
# sampling weights
##################
function samplingDensity(acqData::AcquisitionData,shape::Tuple)
  numEchoes = acqData.numEchoes
  numSlices = acqData.numSlices
  weights = Array{Vector{ComplexF64}}(undef,numEchoes)
  for echo=1:numEchoes
    tr = trajectory(acqData,echo)
    nodes = kspaceNodes(tr)[:,acqData.subsampleIndices[echo]]
    plan = NFFTPlan(nodes, shape,3, 1.25)
    weights[echo] = sqrt.(sdc(plan))
  end
  return weights
end

#########################################################################
# convert acqData for a reconstruction with a encodingSize (resolution)
#########################################################################
function changeEncodingSize2D(acqData::AcquisitionData,newEncodingSize::Vector{Int64})
  dest = deepcopy(acqData)
  changeEncodingSize2D!(dest,newEncodingSize)
end

function changeEncodingSize2D!(acqData::AcquisitionData,newEncodingSize::Vector{Int64})
  fac = acqData.encodingSize ./ newEncodingSize
  idx = Vector{Vector{Int64}}(undef,acqData.numEchoes)

  for i=1:acqData.numEchoes
    tr = trajectory(acqData,i)
    nodes = fac .* kspaceNodes(tr)

    # filter out nodes with magnitude > 0.5
    idxX = findall(x->(x>=-0.5)&&(x<0.5), nodes[1,:])
    idxY = findall(x->(x>=-0.5)&&(x<0.5), nodes[2,:])
    idx[i] = intersect(idxX,idxY)

    tr.nodes = nodes[:,idx[i]]
    times = readoutTimes(tr)
    tr.times = times[idx[i]]
  end

  # find relevant kspace data
  kdata2 = Array{Matrix{ComplexF64}}(undef,acqData.numEchoes,acqData.numSlices,acqData.numReps)
  for rep=1:acqData.numReps
    for slice=1:acqData.numSlices
      for echo=1:acqData.numEchoes
        kdata2[echo,slice,rep] = 1.0/prod(fac) * acqData.kdata[echo,slice,rep][idx[echo],:]
      end
    end
  end
  acqData.kdata = kdata2

  return acqData
end
