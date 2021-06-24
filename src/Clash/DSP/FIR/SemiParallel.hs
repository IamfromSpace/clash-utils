module Clash.DSP.FIR.SemiParallel (
        macUnit,
        integrateAndDump,
        semiParallelFIRSystolic,
        semiParallelFIRTransposed,
        semiParallelFIRTransposedBlockRam,
    ) where

import Clash.Prelude

import Clash.DSP.Complex
import Clash.DSP.MAC
import Clash.Counter

shiftReg 
    :: (HiddenClockResetEnable dom, NFDataX a, KnownNat n, Num a)
    => Signal dom Bool
    -> Signal dom a
    -> Signal dom (Vec n a)
shiftReg shift dat = res
    where
    res = regEn (repeat 0) shift 
        $ (+>>) <$> dat <*> res

macUnit
    :: forall n dom coeffType inputType outputType
    .  (HiddenClockResetEnable dom, KnownNat n, NFDataX inputType, Num inputType, NFDataX outputType, Num outputType, Num coeffType, NFDataX coeffType)
    => MAC dom coeffType inputType outputType
    -> Vec n coeffType                               -- ^ Filter coefficients
    -> Signal dom (Index n)                          -- ^ Index to multiply
    -> Signal dom Bool                               -- ^ Shift
    -> Signal dom Bool                               -- ^ Step
    -> Signal dom outputType                         -- ^ Sample
    -> Signal dom inputType                          -- ^ MAC cascade in
    -> (Signal dom outputType, Signal dom inputType) -- ^ (MAC'd sample out, delayed input sample out)
macUnit mac coeffs idx shiftSamples step cascadeIn sampleIn = (macD, sampleToMul)
    where

    sampleShiftReg :: Signal dom (Vec n inputType)
    sampleShiftReg =  shiftReg (step .&&. shiftSamples) sampleIn

    sampleToMul = regEn 0 step $ (!!) <$> sampleShiftReg <*> idx
    coeffToMul  = regEn 0 step $ (coeffs !!) <$> idx
    macD        = regEn 0 step $ mac step coeffToMul sampleToMul cascadeIn

integrateAndDump
    :: (HiddenClockResetEnable dom, Num a, NFDataX a)
    => Signal dom Bool -- ^ Input valid
    -> Signal dom Bool -- ^ Reset accumulator to 0.
    -> Signal dom a    -- ^ Data in
    -> Signal dom a    -- ^ Integrated data out
integrateAndDump step reset sampleIn = sum
    where
    sum = regEn 0 step $ mux reset 0 sum + sampleIn

semiParallelFIRSystolic
    :: forall numStages coeffsPerStage coeffType inputType outputType dom
    .  (HiddenClockResetEnable dom, KnownNat coeffsPerStage, KnownNat numStages, NFDataX inputType, NFDataX outputType, Num inputType, Num outputType, Num coeffType, NFDataX coeffType)
    => MAC dom coeffType inputType outputType
    -> Vec (numStages + 1) (Vec coeffsPerStage coeffType)        -- ^ Filter coefficients partitioned by stage
    -> Signal dom Bool                                           -- ^ Input valid
    -> Signal dom inputType                                      -- ^ Sample
    -> (Signal dom Bool, Signal dom outputType, Signal dom Bool) -- ^ (Output valid, output data, ready)
semiParallelFIRSystolic mac coeffs valid sampleIn = (validOut, dataOut, ready)
    where
    sampleOut = foldl func (0, sampleIn) (zip3 coeffs indices shifts)
        where
        func 
            :: (Signal dom outputType, Signal dom inputType)
            -> (Vec coeffsPerStage coeffType, Signal dom (Index coeffsPerStage), Signal dom Bool)
            -> (Signal dom outputType, Signal dom inputType)
        func (cascadeIn, sampleIn) (coeffs, idx, shift) = macUnit mac coeffs idx shift globalStep cascadeIn sampleIn

    address :: Signal dom (Index coeffsPerStage)
    address = wrappingCounter maxBound globalStep

    ready :: Signal dom Bool
    ready =  address .==. pure maxBound

    globalStep :: Signal dom Bool
    globalStep =  not <$> ready .||. valid

    shifts :: Vec (numStages + 1) (Signal dom Bool)
    shifts =  iterateI (regEn False globalStep) ready

    indices :: Vec (numStages + 1) (Signal dom (Index coeffsPerStage))
    indices =  iterateI (regEn 0 globalStep) address

    validOut :: Signal dom Bool
    validOut =  globalStep .&&. (regEn False globalStep $ regEn False globalStep $ last indices .==. 0)

    dataOut :: Signal dom outputType
    dataOut =  integrateAndDump globalStep validOut $ fst sampleOut

semiParallelFIRTransposed
    :: forall dom numStages coeffsPerStage coeffType inputType outputType
    .  (HiddenClockResetEnable dom, KnownNat numStages, KnownNat coeffsPerStage, 1 <= coeffsPerStage, NFDataX inputType, Num inputType, NFDataX outputType, Num outputType, Num coeffType, NFDataX coeffType)
    => MAC dom coeffType inputType outputType
    -> Vec numStages (Vec coeffsPerStage coeffType)
    -> Signal dom Bool
    -> Signal dom inputType
    -> (Signal dom Bool, Signal dom outputType, Signal dom Bool)
semiParallelFIRTransposed mac coeffs valid sampleIn = (validOut, dataOut, ready)
    where

    delayStage :: Signal dom inputType -> Signal dom inputType
    delayStage x = last $ iterate (SNat @ (numStages + 1)) (regEn 0 ready) x

    delayLine :: Vec coeffsPerStage (Signal dom inputType)
    delayLine =  iterateI delayStage sampleIn

    stageCounter :: Signal dom (Index coeffsPerStage)
    stageCounter =  wrappingCounter 0 globalStep

    globalStep :: Signal dom Bool
    globalStep =  valid .||. stageCounter ./=. 0

    ready :: Signal dom Bool
    ready =  stageCounter .==. pure maxBound 

    newCascadeIn :: Signal dom Bool
    newCascadeIn =  stageCounter .==. 0

    delayedSampleIn :: Signal dom inputType
    delayedSampleIn =  liftA2 (!!) (sequenceA delayLine) stageCounter

    dataOut :: Signal dom outputType
    dataOut =  foldl accumFunc (pure 0) coeffs
        where
        accumFunc :: Signal dom outputType -> Vec coeffsPerStage coeffType -> Signal dom outputType
        accumFunc cascadeIn coeffs = accum
            where
            cascadeIn' = mux newCascadeIn cascadeIn accum
            coeff      = fmap (coeffs !!) stageCounter
            accum      = regEn 0 globalStep $ mac globalStep coeff delayedSampleIn cascadeIn' 

    validOut :: Signal dom Bool
    validOut =  register False (stageCounter .==. pure maxBound)

semiParallelFIRTransposedBlockRam
    :: forall dom numStages coeffsPerStage coeffType inputType outputType
    .  (HiddenClockResetEnable dom, KnownNat numStages, KnownNat coeffsPerStage, 1 <= coeffsPerStage, NFDataX inputType, Num inputType, NFDataX outputType, Num outputType, NFDataX coeffType)
    => MAC dom coeffType inputType outputType
    -> Vec numStages (Vec coeffsPerStage coeffType)
    -> Signal dom Bool
    -> Signal dom inputType
    -> (Signal dom Bool, Signal dom outputType, Signal dom Bool)
semiParallelFIRTransposedBlockRam mac coeffs valid sampleIn = (validOut, dataOut, ready)
    where

    stageCounter :: Signal dom (Index coeffsPerStage)
    stageCounter =  wrappingCounter maxBound globalStep 

    writePtr :: Signal dom (Index (numStages * coeffsPerStage))
    writePtr =  regEn 0 (ready .&&. valid) $ step <$> writePtr
        where
        step x 
            | x == maxBound = 0
            | otherwise     = x + 1

    readPtr :: Signal dom (Index (numStages * coeffsPerStage))
    readPtr =  regEn 0 globalStep $ step <$> readPtr <*> ready <*> writePtr
        where
        step _   True  writePtr = writePtr
        step ptr _     _
            | ptr < snatToNum (SNat @ numStages)
                = ptr + snatToNum (SNat @ ((coeffsPerStage - 1) * numStages))
            | otherwise 
                = ptr - snatToNum (SNat @ numStages)

    --Clash's BlockRam doesn't support a read enable!
    --So fake it with an async ram followed by a register
    --TODO: check this synthesizes to a block ram
    sampleRamOut :: Signal dom inputType
    sampleRamOut 
        = regEn 0 globalStep $ asyncRam 
            (SNat @ (numStages * coeffsPerStage)) 
            readPtr 
            (mux (ready .&&. valid) (Just <$> bundle (writePtr, sampleIn)) (pure Nothing))

    globalStep :: Signal dom Bool
    globalStep =  valid .||. stageCounter ./=. pure maxBound

    ready :: Signal dom Bool
    ready =  stageCounter .==. pure maxBound 

    newCascadeIn :: Signal dom Bool
    newCascadeIn =  regEn False globalStep $ stageCounter .==. 0

    dataOut :: Signal dom outputType
    dataOut =  foldl accumFunc (pure 0) coeffs
        where
        accumFunc :: Signal dom outputType -> Vec coeffsPerStage coeffType -> Signal dom outputType
        accumFunc cascadeIn coeffs = accum
            where
            cascadeIn' = mux newCascadeIn cascadeIn accum
            coeff      = regEn (errorX "initial coeff") globalStep $ fmap (coeffs !!) stageCounter
            accum      = regEn 0 globalStep $ mac globalStep coeff sampleRamOut cascadeIn' 

    validOut :: Signal dom Bool
    validOut =  register False (stageCounter .==. 0)
