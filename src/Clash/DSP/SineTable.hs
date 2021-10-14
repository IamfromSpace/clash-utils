module Clash.DSP.SineTable (
        sines,
        sineTable
    ) where

import Clash.Prelude
import qualified Prelude as P

{-| Compute the values for the sine lookup table -}
sines :: Int -> [Double]
sines size 
    = P.take size 
    $ P.map (\x -> sin(2*pi*(2*(fromIntegral x)+1)/(8*fromIntegral size)))
    $ [0..size-1]

sineTable
    :: forall dom n a
    .  HiddenClockResetEnable dom
    => (Num a, NFDataX a)
    => KnownNat n
    => Vec (2 ^ n) a
    -> Signal dom (Unsigned (n + 2))
    -> Signal dom a
sineTable table addr = mux negD (negate <$> tableRes) tableRes
    where

    --Split up the address
    (neg :: Signal dom Bool, flip :: Signal dom Bool, addr' :: Signal dom (Unsigned n)) 
        = unbundle $ bitCoerce <$> addr

    --Save the negation signal for the cycle after the ram read
    negD = register False neg

    --The table ram
    tableRes = blockRam table (mux flip (complement <$> addr') addr') (pure Nothing)
